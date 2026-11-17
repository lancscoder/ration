import AppKit
import ClaudeBarCore
import Foundation
import Observation
import os

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
    var showCacheReads = false

    @ObservationIgnored private let usageService: UsageService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var started = false

    init(prefs: Preferences? = nil) {
        let prefs = prefs ?? Preferences()
        self.prefs = prefs
        self.usageService = UsageService(pollInterval: TimeInterval(prefs.pollInterval))
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
    }

    /// Loads cached data only (no network); used by `--snapshot`.
    func loadForSnapshot() async {
        let (snapshot, _) = await usageService.loadCached()
        usage = snapshot
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

    /// Manual refresh (`r` / button). Respects rate-limit backoff and a 60 s minimum gap.
    func refresh() {
        Task {
            if await usageService.canFetchNow() {
                startPolling(after: 0)
            }
        }
    }

    func toggleCacheReads() { showCacheReads.toggle() }

    func pollIntervalChanged() {
        Task { await usageService.setPollInterval(TimeInterval(prefs.pollInterval)) }
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
