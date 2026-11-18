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
    var projects: [ProjectTotals] = []
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
    /// The panel shows Settings in place of the dashboard.
    var showingSettings = false

    // Tokens
    var showCacheReads: Bool
    var tokenRange: TokenRange = .week { didSet { recomputeTokens() } }
    private(set) var tokens = TokenViewData()
    private(set) var sessionTokens: [String: SessionTokenSummary] = [:]
    private(set) var logsLoaded = false
    @ObservationIgnored private(set) var logSnapshot = LogSnapshot.empty

    // Sessions
    private(set) var sessions: [SessionInfo] = []
    /// Shown briefly in the sessions card when resume/kill fails.
    var sessionActionError: String?
    /// Non-error feedback for a session action (e.g. "command copied").
    var sessionActionNotice: String?
    @ObservationIgnored private let sessionMonitor = SessionMonitor()
    @ObservationIgnored private var sessionTimer: Timer?
    @ObservationIgnored private var sessionScanInFlight = false
    /// A "waiting" session only lights the menu bar dot this long after its last activity,
    /// so a terminal left open for days doesn't keep it blue forever.
    static let waitingDotWindow: TimeInterval = 30 * 60

    @ObservationIgnored let notifier = Notifier()
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
        Stress.appState = self
        if prefs.notifyUsage || prefs.notifyWaiting { notifier.requestAuthorization() }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task {
            let (snapshot, initialDelay) = await usageService.loadCached()
            self.usage = snapshot
            startPolling(after: initialDelay)
        }
        startLogMonitoring()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [logStore] _ in
            // Best effort: persist the parse cache so the next launch is incremental.
            let sem = DispatchSemaphore(value: 0)
            Task.detached { await logStore.flush(); sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
    }

    /// After sleep everything on screen is stale: refresh local data at once and the
    /// usage endpoint once the network is back, unless a poll happened recently
    /// or we're backing off. The normal minimum interval still applies.
    private func didWake() {
        now = Date()
        refreshLogs()
        Task {
            try? await Task.sleep(for: .seconds(5)) // give Wi-Fi a moment to reconnect
            now = Date()
            if await usageService.canFetchNow(minimumGap: BackoffPolicy.minimumPollInterval) {
                startPolling(after: 0)
            }
        }
    }

    /// Loads cached data only (no network); used by `--snapshot`.
    func loadForSnapshot() async {
        let (snapshot, _) = await usageService.loadCached()
        usage = snapshot
        let logs = await logStore.refresh()
        applyLogs(logs)
        await recomputeTokensNow()
        await scanSessions()
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
        let isNewData = snapshot.fetchedAt != usage.fetchedAt
        usage = snapshot
        now = Date()
        if isNewData, snapshot.status == .ok {
            checkUsageThresholds()
            scheduleResetReminders()
        }
    }

    private func checkUsageThresholds() {
        guard prefs.notifyUsage, let response = usage.response else { return }
        let limits = [response.session, response.weekly].compactMap { $0 }
        let result = ThresholdTracker.evaluate(limits: limits, thresholds: prefs.parsedNotifyThresholds, fired: notifier.firedKeys)
        notifier.firedKeys = result.fired
        for alert in result.alerts { notifier.sendUsageAlert(alert, now: now) }
    }

    private func scheduleResetReminders() {
        guard prefs.notifyReset, let response = usage.response else { return }
        let limits = [response.session, response.weekly].compactMap { $0 }
        for limit in ThresholdTracker.resetReminders(limits: limits, now: now) {
            notifier.scheduleResetReminder(limit)
        }
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
        Task { [weak self, logStore] in
            let paths = await logStore.watchedPaths
            let watcher = DirectoryWatcher(paths: paths, latency: 2) { [weak self] in
                Task { @MainActor in self?.refreshLogs() }
            }
            watcher.start()
            self?.logWatcher = watcher
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
            refreshSessions()
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

    private func logsDidChange() {}

    // MARK: Sessions

    func refreshSessions() {
        guard !sessionScanInFlight else { return }
        sessionScanInFlight = true
        Task {
            await scanSessions()
            sessionScanInFlight = false
        }
    }

    private func scanSessions() async {
        let logs = logSnapshot
        let found = await sessionMonitor.scan(sessionFiles: logs.sessionFiles, sessionCwds: logs.sessionCwds, summaries: sessionTokens,
                                             recentWindow: TimeInterval(prefs.endedSessionDays) * 86400)
        let previous = sessions
        if found != previous {
            sessions = found
            sessionsDidChange(from: previous, to: found)
        }
    }

    private func sessionsDidChange(from old: [SessionInfo], to new: [SessionInfo]) {
        guard prefs.notifyWaiting, !old.isEmpty else { return }
        for session in ThresholdTracker.newlyWaiting(old: old, new: new) {
            notifier.sendWaiting(session)
        }
    }

    func resume(_ session: SessionInfo) {
        do {
            let outcome = try TerminalLauncher.resume(sessionId: session.sessionId, cwd: session.cwd,
                                                      terminalID: prefs.terminal, customTemplate: prefs.customTerminalCommand)
            sessionActionError = nil
            if case .copiedCommand(let app) = outcome {
                showSessionNotice("Resume command copied. Paste it into \(app).")
            }
        } catch {
            showSessionError(error.localizedDescription)
        }
    }

    func kill(_ session: SessionInfo) {
        guard let pid = session.pid else { return }
        do {
            try ProcessControl.terminate(pid: pid, procStart: session.procStart)
            sessionActionError = nil
        } catch ProcessControl.TerminateError.notRunning {
            sessionActionError = nil
        } catch ProcessControl.TerminateError.pidReused {
            showSessionError("That process is no longer the Claude session; not killed.")
        } catch {
            showSessionError("Couldn't stop the session (\(error)).")
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            refreshSessions()
        }
    }

    private func showSessionNotice(_ message: String) {
        sessionActionNotice = message
        Task {
            try? await Task.sleep(for: .seconds(8))
            if sessionActionNotice == message { sessionActionNotice = nil }
        }
    }

    private func showSessionError(_ message: String) {
        sessionActionError = message
        Task {
            try? await Task.sleep(for: .seconds(6))
            if sessionActionError == message { sessionActionError = nil }
        }
    }

    var sessionDotState: SessionState? {
        if sessions.contains(where: { $0.state == .busy }) { return .busy }
        let recentWaiting = sessions.contains {
            $0.state == .waiting && now.timeIntervalSince($0.lastActivity ?? .distantPast) < Self.waitingDotWindow
        }
        return recentWaiting ? .waiting : nil
    }

    func toggleCacheReads() { showCacheReads.toggle() }

    func historyDaysChanged() { recomputeTokens() }

    private func recomputeTokens() {
        Task { await recomputeTokensNow() }
    }

    private func recomputeTokensNow() async {
        let records = logSnapshot.records
        let cwds = logSnapshot.sessionCwds
        let range = tokenRange
        let historyDays = prefs.historyDays
        let calendar = Calendar.current
        let (data, sessions) = await Task.detached(priority: .userInitiated) { () -> (TokenViewData, [String: SessionTokenSummary]) in
            let now = Date()
            let data = TokenViewData(
                range: range,
                buckets: TokenAggregator.buckets(records, range: range, now: now, calendar: calendar, historyDays: historyDays),
                totals: TokenAggregator.totalsByModel(records, range: range, now: now, calendar: calendar, historyDays: historyDays),
                projects: TokenAggregator.totalsByProject(records, sessionCwds: cwds, range: range, now: now,
                                                          calendar: calendar, historyDays: historyDays),
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
