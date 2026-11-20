import Foundation
import os

public struct SessionInfo: Identifiable, Sendable, Equatable {
    public var id: String { sessionId }
    public var sessionId: String
    public var pid: Int32?
    public var procStart: String?
    public var cwd: String?
    public var name: String?
    public var state: SessionState
    public var lastActivity: Date?
    public var model: String?
    public var tokens: TokenCounts?
    /// Waiting on a permission prompt (known only with hooks installed).
    public var needsPermission: Bool = false
    public var isLive: Bool { pid != nil }

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Unknown project" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// `~/.claude/sessions/<pid>.json`, written by Claude Code for each running process.
struct LiveSessionFile: Decodable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var status: String?
    var procStart: String?
    var name: String?
    var startedAt: Double?
    var updatedAt: Double?
    var statusUpdatedAt: Double?

    var lastUpdate: Date? {
        (statusUpdatedAt ?? updatedAt ?? startedAt).map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
    }
}

/// Finds running Claude Code sessions and works out their state.
public actor SessionMonitor {
    private static let log = Logger(subsystem: Log.subsystem, category: "sessions")

    private let sessionDirs: [URL]
    private let hookStateDir: URL?

    public init(sessionDirs: [URL] = AppPaths.claudeRoots().map { $0.appendingPathComponent("sessions", isDirectory: true) },
                hookStateDir: URL? = AppPaths.hookStateDirectory) {
        self.sessionDirs = sessionDirs
        self.hookStateDir = hookStateDir
    }

    public var watchedPaths: [String] { sessionDirs.map(\.path).filter { FileManager.default.fileExists(atPath: $0) } }

    /// - Parameters:
    ///   - sessionFiles / sessionCwds / summaries: from the log store.
    ///   - recentWindow: how far back finished sessions are listed.
    public func scan(sessionFiles: [String: URL],
                     sessionCwds: [String: String],
                     summaries: [String: SessionTokenSummary],
                     now: Date = Date(),
                     recentWindow: TimeInterval = 24 * 3600,
                     limit: Int = 12) -> [SessionInfo] {
        var byId: [String: SessionInfo] = [:]
        let hookStates = hookStateDir.map { HookStateStore.load(from: $0) } ?? [:]

        for file in liveFiles() {
            guard ResumeCommand.isSafeSessionId(file.sessionId),
                  ProcessControl.matches(pid: file.pid, procStart: file.procStart) else { continue }

            let merged = HookStateStore.merge(hook: hookStates[file.sessionId], fileStatus: file.status,
                                              fileUpdated: file.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) })
            let transcript = sessionFiles[file.sessionId]
            let mtime = transcript.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
            // The transcript is only needed when Claude Code didn't report a status.
            let lastEntry = (merged.status == nil) ? transcript.flatMap { TranscriptTail.lastEntry(of: $0) } : nil
            let state = SessionStateHeuristic.resolve(SessionSignals(
                processAlive: true, reportedStatus: merged.status, lastWrite: mtime, lastEntry: lastEntry, now: now))

            let summary = summaries[file.sessionId]
            let activity = [mtime, file.lastUpdate, summary?.lastActivity].compactMap { $0 }.max()
            let info = SessionInfo(sessionId: file.sessionId, pid: file.pid, procStart: file.procStart,
                                   cwd: file.cwd ?? sessionCwds[file.sessionId], name: file.name,
                                   state: state, lastActivity: activity, model: summary?.lastModel, tokens: summary?.counts,
                                   needsPermission: merged.needsPermission && state == .waiting)
            if let existing = byId[file.sessionId], existing.state <= info.state { continue }
            byId[file.sessionId] = info
        }

        for (sid, summary) in summaries where byId[sid] == nil && now.timeIntervalSince(summary.lastActivity) <= recentWindow {
            byId[sid] = SessionInfo(sessionId: sid, pid: nil, procStart: nil, cwd: sessionCwds[sid], name: nil, state: .idle,
                                    lastActivity: summary.lastActivity, model: summary.lastModel, tokens: summary.counts)
        }

        let sorted = byId.values.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
        // Live sessions are always listed; finished ones fill up to `limit`.
        let live = sorted.filter(\.isLive)
        let rest = sorted.filter { !$0.isLive }.prefix(max(0, limit - live.count))
        return live + rest
    }

    private func liveFiles() -> [LiveSessionFile] {
        var out: [LiveSessionFile] = []
        let decoder = JSONDecoder()
        for dir in sessionDirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".json") {
                guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path),
                      let file = try? decoder.decode(LiveSessionFile.self, from: data) else { continue }
                out.append(file)
            }
        }
        return out
    }
}
