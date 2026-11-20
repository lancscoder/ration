import Foundation

// Optional "hooks mode": Claude Code runs `ration-hook <state> <dir>` on a few
// hook events; the helper records the session's latest state in `<dir>/<id>.json`.
// That adds what Claude Code's own session files don't say — that a session is
// blocked on a permission prompt — and updates instantly.

/// The state a hook reported for one session.
public struct HookStateRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case busy, waiting, permission, ended
    }
    public var state: State
    /// Seconds since 1970.
    public var at: Double
    public var event: String?

    public init(state: State, at: Double, event: String? = nil) {
        self.state = state
        self.at = at
        self.event = event
    }

    public var date: Date { Date(timeIntervalSince1970: at) }
}

/// Reads and writes the per-session state files.
public enum HookStateStore {
    /// Writes (or for `.ended`, removes) the state file. Used by the helper.
    public static func record(_ state: HookStateRecord.State, sessionId: String, event: String?, in dir: URL, now: Date = Date()) throws {
        guard ResumeCommand.isSafeSessionId(sessionId) else { return }
        let file = dir.appendingPathComponent("\(sessionId).json")
        if state == .ended {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(HookStateRecord(state: state, at: now.timeIntervalSince1970, event: event))
        try data.write(to: file, options: .atomic)
    }

    public static func load(from dir: URL) -> [String: HookStateRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: HookStateRecord] = [:]
        let decoder = JSONDecoder()
        for name in names where name.hasSuffix(".json") {
            let sid = String(name.dropLast(5))
            guard ResumeCommand.isSafeSessionId(sid),
                  let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path),
                  let record = try? decoder.decode(HookStateRecord.self, from: data) else { continue }
            out[sid] = record
        }
        return out
    }

    /// Removes state files older than `maxAge` (sessions that ended without a SessionEnd hook).
    public static func prune(_ dir: URL, olderThan maxAge: TimeInterval = 2 * 86400, now: Date = Date()) {
        for (sid, record) in load(from: dir) where now.timeIntervalSince(record.date) > maxAge {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid).json"))
        }
    }

    /// Combines a hook record with the status Claude Code wrote in its session file.
    ///
    /// The newer report wins, except that "needs permission" holds until Claude Code
    /// says it is busy again *after* the prompt (approving runs the tool), because
    /// Claude Code itself also reports a prompt as plain `idle`.
    public static func merge(hook: HookStateRecord?, fileStatus: String?, fileUpdated: Date?) -> (status: String?, needsPermission: Bool) {
        guard let hook, hook.state != .ended else { return (fileStatus, false) }
        let fileIsNewer = fileUpdated.map { $0.timeIntervalSince(hook.date) > 1 } ?? false
        switch hook.state {
        case .permission:
            let busyAgain = fileIsNewer && SessionStateHeuristic.isBusyStatus(fileStatus)
            return busyAgain ? (fileStatus, false) : ("waiting", true)
        case .busy, .waiting:
            return fileIsNewer && fileStatus != nil ? (fileStatus, false) : (hook.state.rawValue, false)
        case .ended:
            return (fileStatus, false)
        }
    }
}

/// Adds and removes Ration's entries in Claude Code's `settings.json`,
/// leaving every other setting and hook untouched.
public enum HookInstaller {
    /// Every command Ration installs contains this, which is how its entries are recognised.
    public static let marker = "ration-hook"

    public struct Entry: Sendable, Equatable {
        public var event: String
        public var matcher: String?
        public var state: HookStateRecord.State
    }

    public static let entries: [Entry] = [
        Entry(event: "UserPromptSubmit", matcher: nil, state: .busy),
        Entry(event: "PostToolUse", matcher: nil, state: .busy),
        Entry(event: "PermissionRequest", matcher: nil, state: .permission),
        Entry(event: "Notification", matcher: "permission_prompt", state: .permission),
        Entry(event: "Notification", matcher: "idle_prompt", state: .waiting),
        Entry(event: "Stop", matcher: nil, state: .waiting),
        Entry(event: "SessionEnd", matcher: nil, state: .ended),
    ]

    /// Runs the helper if it still exists, and never fails the hook if it doesn't
    /// (e.g. Ration was moved or deleted).
    public static func command(helper: String, state: HookStateRecord.State, stateDir: String) -> String {
        let h = ResumeCommand.shellQuote(helper)
        return "[ -x \(h) ] && \(h) \(state.rawValue) \(ResumeCommand.shellQuote(stateDir)) || true"
    }

    public static func install(into settings: [String: Any], helper: String, stateDir: String) -> [String: Any] {
        var settings = uninstall(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for entry in entries {
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command(helper: helper, state: entry.state, stateDir: stateDir), "timeout": 5]],
            ]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[entry.event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let others = handlers.filter { !isOurs($0) }
                if others.count == handlers.count { return group }
                if others.isEmpty { return nil }
                var g = group
                g["hooks"] = others
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// Installed, but pointing at another copy of Ration or missing entries.
        case outdated
    }

    public static func status(of settings: [String: Any], helper: String, stateDir: String) -> Status {
        let ours = ourCommands(settings)
        if ours.isEmpty { return .notInstalled }
        let expected = Set(entries.map { command(helper: helper, state: $0.state, stateDir: stateDir) })
        return Set(ours) == expected && ours.count == entries.count ? .installed : .outdated
    }

    public static func ourCommandsPresent(_ settings: [String: Any]) -> Bool { !ourCommands(settings).isEmpty }

    static func ourCommands(_ settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }
            .filter(isOurs).compactMap { $0["command"] as? String }
    }

    private static func isOurs(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(marker) == true
    }
}

/// Reading and writing `settings.json` safely.
public enum ClaudeSettingsFile {
    public enum FileError: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't read Claude Code's settings.json (\(why)). Nothing was changed."
            }
        }
    }

    /// A missing file is an empty object; an unparsable one is an error, so it is never overwritten.
    public static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FileError.unreadable("not a JSON object")
            }
            return object
        } catch let error as FileError {
            throw error
        } catch {
            throw FileError.unreadable(error.localizedDescription)
        }
    }

    /// Saves a backup of the current file next to it, then writes atomically.
    public static func save(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".ration-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
