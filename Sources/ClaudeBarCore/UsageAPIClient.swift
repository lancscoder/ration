import Foundation
import os

public enum UsageFetchResult: Sendable {
    case success(UsageResponse, Data)
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized(Int)
    case httpError(Int)
    case networkError(String)
    case decodingError(String)
}

/// Client for the undocumented `GET https://api.anthropic.com/api/oauth/usage`.
public struct UsageAPIClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let log = Logger(subsystem: Log.subsystem, category: "api")

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    public func fetch(accessToken: String) async -> UsageFetchResult {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeBar/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            Self.log.error("usage request failed: \(error.localizedDescription, privacy: .public)")
            return .networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return .networkError("no HTTP response") }
        Self.log.info("usage endpoint HTTP \(http.statusCode)")

        switch http.statusCode {
        case 200:
            do {
                return .success(try UsageResponse.decode(data), data)
            } catch {
                return .decodingError(String(describing: error))
            }
        case 429:
            let retry = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            return .rateLimited(retryAfter: retry)
        case 401, 403:
            return .unauthorized(http.statusCode)
        default:
            return .httpError(http.statusCode)
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP-date (RFC 9110).
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = Double(raw) { return secs >= 0 ? secs : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
