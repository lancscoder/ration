import AppKit
import ClaudeBarCore
import Foundation
import Observation
import os

/// Aggregated token data for the current range, computed off the main thread.
struct TokenViewData: Equatable {
    var range: TokenRange = .week
    var buckets: [TokenBucket] = []
    var totals: [ModelTotals] = []
    var granularity: BucketGranularity = .day
}

/// The single source of truth the views read. All mutation happens on the
/// main actor; the heavy lifting lives in actors in ClaudeBarCore.
@MainActor
@Observable
final class AppState {
    private static let log = Logger(subsystem: Log.subsystem, category: "app")

    let prefs: Preferences

    // Plan limits
    private(set) var usage = UsageSnapshot()
    /// Ticks every 15 s so countdowns stay current.
    private(set) var now = Date()

    // Tokens
    var showCacheReads: Bool
    var tokenRange: TokenRange = .week { didSet { recomputeTokens() } }
    private(set) var tokens = TokenViewData()
    private(set) var sessionTokens: [String: SessionTokenSummary] = [:]
    private(set) var logsLoaded = false
    @ObservationIgnored private(set) var logSnapshot = LogSnapshot.empty

    @ObservationIgnored private let usageService: UsageService
    @ObservationIgnored private let logStore: LogStore
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var logTimer: Timer?
    @ObservationIgnored private var logWatcher: DirectoryWatcher?
    @ObservationIgnored private var logRefreshInFlight = false
    @ObservationIgnored private var logRefreshPending = false
    @ObservationIgnored private var started = false

    init(prefs: Preferences? = nil) {
        let prefs = prefs ?? Preferences()
        self.prefs = prefs
        self.showCacheReads = !prefs.hideCacheReadsByDefault
        self.usageService = UsageService(pollInterval: TimeInterval(prefs.pollInterval))
        self.logStore = LogStore()
    }

    func start() {
        guard !started else { return }
        started = true
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task {
            let (snapshot, initialDelay) = await usageService.loadCached()
            self.usage = snapshot
            startPolling(after: initialDelay)
        }
        startLogMonitoring()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [logStore] _ in
            // Best effort: persist the parse cache so the next launch is incremental.
            let sem = DispatchSemaphore(value: 0)
            Task.detached { await logStore.flush(); sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
    }

    /// Loads cached data only (no network); used by `--snapshot`.
    func loadForSnapshot() async {
        let (snapshot, _) = await usageService.loadCached()
        usage = snapshot
        let logs = await logStore.refresh()
        applyLogs(logs)
        await recomputeTokensNow()
        now = Date()
    }

    // MARK: Usage polling

    private func startPolling(after initialDelay: TimeInterval) {
        pollTask?.cancel()
        pollTask = Task { [weak self, usageService] in
            if initialDelay > 0 {
                try? await Task.sleep(for: .seconds(initialDelay))
            }
            while !Task.isCancelled {
                let (snapshot, delay) = await usageService.poll()
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.applyUsage(snapshot) }
                try? await Task.sleep(for: .seconds(max(5, delay)))
            }
        }
    }

    private func applyUsage(_ snapshot: UsageSnapshot) {
        usage = snapshot
        now = Date()
    }

    /// Manual refresh (`r` / button). Respects rate-limit backoff and a 60 s
    /// minimum gap for the quota; local logs always refresh.
    func refresh() {
        refreshLogs()
        Task {
            if await usageService.canFetchNow() {
                startPolling(after: 0)
            }
        }
    }

    func pollIntervalChanged() {
        Task { await usageService.setPollInterval(TimeInterval(prefs.pollInterval)) }
    }

    // MARK: Local logs

    private func startLogMonitoring() {
        refreshLogs()
        Task {
            let paths = await logStore.watchedPaths
            let watcher = DirectoryWatcher(paths: paths, latency: 2) { [weak self] in
                Task { @MainActor in self?.refreshLogs() }
            }
            watcher.start()
            self.logWatcher = watcher
        }
        // Fallback in case FSEvents misses something.
        logTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLogs() }
        }
    }

    /// Coalesces bursts of FSEvents into one refresh at a time.
    func refreshLogs() {
        if logRefreshInFlight {
            logRefreshPending = true
            return
        }
        logRefreshInFlight = true
        Task {
            let snapshot = await logStore.refresh()
            applyLogs(snapshot)
            await recomputeTokensNow()
            logRefreshInFlight = false
            if logRefreshPending {
                logRefreshPending = false
                try? await Task.sleep(for: .seconds(3))
                refreshLogs()
            }
        }
    }

    private func applyLogs(_ snapshot: LogSnapshot) {
        let changed = snapshot.scannedAt != logSnapshot.scannedAt
        logSnapshot = snapshot
        logsLoaded = true
        if changed { logsDidChange() }
    }

    /// Hook for the session monitor (M4).
    private func logsDidChange() {}

    func toggleCacheReads() { showCacheReads.toggle() }

    private func recomputeTokens() {
        Task { await recomputeTokensNow() }
    }

    private func recomputeTokensNow() async {
        let records = logSnapshot.records
        let range = tokenRange
        let historyDays = prefs.historyDays
        let calendar = Calendar.current
        let (data, sessions) = await Task.detached(priority: .userInitiated) { () -> (TokenViewData, [String: SessionTokenSummary]) in
            let now = Date()
            let data = TokenViewData(
                range: range,
                buckets: TokenAggregator.buckets(records, range: range, now: now, calendar: calendar, historyDays: historyDays),
                totals: TokenAggregator.totalsByModel(records, range: range, now: now, calendar: calendar, historyDays: historyDays),
                granularity: TokenAggregator.granularity(for: range)
            )
            return (data, TokenAggregator.sessions(records))
        }.value
        guard range == tokenRange else { return } // superseded
        if data != tokens { tokens = data }
        sessionTokens = sessions
    }

    // MARK: Derived

    var isUsageStale: Bool { usage.isStale(now: now) }

    var statusMessage: String? {
        switch usage.status {
        case .starting, .ok: return nil
        case .rateLimited(let until): return "Rate limited. Retrying in \(Fmt.duration(until.timeIntervalSince(now)))."
        case .loginStale: return "Login stale. Run `claude` to refresh it."
        case .noCredentials(let why): return why
        case .error(let why): return "Couldn't update: \(why)"
        }
    }
}
