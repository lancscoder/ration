import Foundation
import os

public enum UsageStatus: Sendable, Equatable {
    /// Nothing fetched yet this run.
    case starting
    case ok
    /// HTTP 429; showing last good data until `until`.
    case rateLimited(until: Date)
    /// Access token expired or rejected. Run `claude` to refresh it.
    case loginStale
    case noCredentials(String)
    case error(String)
}

public struct UsageSnapshot: Sendable, Equatable {
    public var response: UsageResponse?
    public var fetchedAt: Date?
    public var status: UsageStatus
    public var plan: String?
    public var samples: [QuotaSample]

    public init(response: UsageResponse? = nil, fetchedAt: Date? = nil, status: UsageStatus = .starting, plan: String? = nil, samples: [QuotaSample] = []) {
        self.response = response
        self.fetchedAt = fetchedAt
        self.status = status
        self.plan = plan
        self.samples = samples
    }

    /// True when the data is older than `maxAge` or the last fetch failed.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 15 * 60) -> Bool {
        guard let fetchedAt else { return true }
        if now.timeIntervalSince(fetchedAt) > maxAge { return true }
        switch status {
        case .ok, .starting: return false
        default: return true
        }
    }
}

/// Owns the polling state for the plan-limits endpoint: credentials, backoff,
/// disk cache and quota samples. The UI only ever sees `UsageSnapshot`s.
public actor UsageService {
    private static let log = Logger(subsystem: Log.subsystem, category: "usage")

    private let credentialStore: CredentialStore
    private let client: UsageAPIClient
    private let cache: UsageCache
    private var backoff: BackoffPolicy
    private var credentials: OAuthCredentials?
    private var rateLimitedUntil: Date?
    private var snapshot = UsageSnapshot()

    /// How soon to re-check the Keychain when the login is stale.
    public static let staleLoginRecheck: TimeInterval = 60

    public init(credentialStore: CredentialStore = CredentialStore(),
                client: UsageAPIClient = UsageAPIClient(),
                cache: UsageCache = UsageCache(),
                pollInterval: TimeInterval = BackoffPolicy.defaultPollInterval) {
        self.credentialStore = credentialStore
        self.client = client
        self.cache = cache
        self.backoff = BackoffPolicy(baseInterval: pollInterval)
    }

    public func setPollInterval(_ seconds: TimeInterval) {
        backoff.baseInterval = BackoffPolicy.clamp(seconds)
    }

    public var pollInterval: TimeInterval { backoff.baseInterval }

    /// Loads the on-disk cache so the UI has something immediately.
    /// Returns the snapshot and the delay before the first network fetch
    /// (a recent cache means we wait instead of hitting the endpoint on every launch).
    public func loadCached(now: Date = Date()) async -> (UsageSnapshot, TimeInterval) {
        snapshot.samples = await cache.loadSamples()
        guard let cached = await cache.loadUsage() else { return (snapshot, 0) }
        snapshot.response = cached.response
        snapshot.fetchedAt = cached.fetchedAt
        let age = now.timeIntervalSince(cached.fetchedAt)
        return (snapshot, max(0, min(backoff.baseInterval - age, backoff.baseInterval)))
    }

    public var current: UsageSnapshot { snapshot }

    /// Whether a manual refresh would hit the network right now.
    public func canFetchNow(now: Date = Date(), minimumGap: TimeInterval = 60) -> Bool {
        if let until = rateLimitedUntil, now < until { return false }
        if let last = snapshot.fetchedAt, now.timeIntervalSince(last) < minimumGap { return false }
        return true
    }

    /// Performs one poll. Returns the new snapshot and the delay until the next poll.
    public func poll(now: Date = Date()) async -> (UsageSnapshot, TimeInterval) {
        if let until = rateLimitedUntil, now < until {
            return (snapshot, until.timeIntervalSince(now))
        }

        // (Re)load credentials when we have none or ours have expired.
        // Claude Code rotates the token itself; we only ever read it.
        if credentials == nil || credentials!.isExpired(at: now) {
            do {
                credentials = try await Self.loadCredentials(credentialStore)
                snapshot.plan = credentials?.planLabel
            } catch CredentialError.notFound {
                snapshot.status = .noCredentials("No Claude Code login found. Run `claude` and log in.")
                return (snapshot, Self.staleLoginRecheck)
            } catch CredentialError.accessDenied(let why) {
                snapshot.status = .noCredentials("Keychain access denied (\(why)).")
                return (snapshot, Self.staleLoginRecheck * 5)
            } catch {
                snapshot.status = .error("Could not read credentials.")
                return (snapshot, Self.staleLoginRecheck * 5)
            }
        }
        guard let creds = credentials, !creds.isExpired(at: now) else {
            snapshot.status = .loginStale
            return (snapshot, Self.staleLoginRecheck)
        }

        switch await client.fetch(accessToken: creds.accessToken) {
        case .success(let response, let raw):
            backoff.recordSuccess()
            rateLimitedUntil = nil
            snapshot.response = response
            snapshot.fetchedAt = now
            snapshot.status = .ok
            await cache.saveUsage(raw, fetchedAt: now)
            snapshot.samples = await cache.appendSample(QuotaSample(response: response, at: now))
            return (snapshot, backoff.normalDelay)

        case .rateLimited(let retryAfter):
            let delay = backoff.recordFailure(retryAfter: retryAfter)
            let until = now.addingTimeInterval(delay)
            rateLimitedUntil = until
            snapshot.status = .rateLimited(until: until)
            Self.log.notice("rate limited; backing off \(Int(delay))s")
            return (snapshot, delay)

        case .unauthorized:
            // Token rejected: forget it so the next poll re-reads the Keychain
            // (Claude Code may have refreshed it meanwhile).
            credentials = nil
            snapshot.status = .loginStale
            return (snapshot, Self.staleLoginRecheck)

        case .httpError(let code):
            let delay = backoff.recordFailure()
            snapshot.status = .error("HTTP \(code)")
            return (snapshot, min(delay, backoff.baseInterval))

        case .networkError(let message):
            backoff.recordFailure()
            snapshot.status = .error(message)
            return (snapshot, 60)

        case .decodingError(let message):
            Self.log.error("decode failed: \(message, privacy: .public)")
            backoff.recordFailure()
            snapshot.status = .error("Unexpected response from usage endpoint")
            return (snapshot, backoff.baseInterval)
        }
    }

    private static func loadCredentials(_ store: CredentialStore) async throws -> OAuthCredentials {
        // `security` can block on a Keychain prompt; keep it off the cooperative pool.
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(with: Result { try store.load() })
            }
        }
    }
}
