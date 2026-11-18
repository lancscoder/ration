import Foundation

public enum SessionState: String, Sendable, Equatable, Comparable {
    /// Claude is working (generating, running tools).
    case busy
    /// The process is alive and Claude finished its turn: it's your move.
    case waiting
    /// No running process.
    case idle

    private var rank: Int {
        switch self {
        case .busy: return 0
        case .waiting: return 1
        case .idle: return 2
        }
    }
    public static func < (a: SessionState, b: SessionState) -> Bool { a.rank < b.rank }
}

/// The last user/assistant entry of a transcript.
public struct LastEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `stopReason` nil means the turn was still streaming when written.
        case assistant(stopReason: String?, hasToolUse: Bool)
        /// A typed prompt or a tool result being sent back.
        case user(isToolResult: Bool)
    }
    public var kind: Kind
    public var timestamp: Date?

    public init(kind: Kind, timestamp: Date? = nil) {
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// Everything the heuristic looks at for one session.
public struct SessionSignals: Sendable, Equatable {
    public var processAlive: Bool
    /// `status` from Claude Code's own `~/.claude/sessions/<pid>.json`, if present
    /// (or, later, from a hooks-written state file).
    public var reportedStatus: String?
    public var lastWrite: Date?
    public var lastEntry: LastEntry?
    public var now: Date

    public init(processAlive: Bool, reportedStatus: String? = nil, lastWrite: Date? = nil, lastEntry: LastEntry? = nil, now: Date = Date()) {
        self.processAlive = processAlive
        self.reportedStatus = reportedStatus
        self.lastWrite = lastWrite
        self.lastEntry = lastEntry
        self.now = now
    }
}

/// Busy / waiting / idle, in one place.
///
/// 1. No live process → idle.
/// 2. A status reported by Claude Code itself wins (`busy`/`working`/`running`
///    → busy; `idle`/`waiting` → waiting). This is the reliable path on current
///    Claude Code; a future hooks mode would feed the same field.
/// 3. Otherwise fall back to the transcript, as in oguzkarcan/claude-usage:
///    written in the last ~10 s → busy; last entry a finished assistant turn →
///    waiting; a pending tool_use, unfinished assistant turn or a user/tool
///    result awaiting a reply → busy.
public enum SessionStateHeuristic {
    public static let recentWriteWindow: TimeInterval = 10

    public static func isBusyStatus(_ status: String?) -> Bool {
        ["busy", "working", "running", "thinking"].contains(status?.lowercased() ?? "")
    }

    public static func isWaitingStatus(_ status: String?) -> Bool {
        ["idle", "waiting", "ready", "waiting_for_input"].contains(status?.lowercased() ?? "")
    }

    public static func resolve(_ s: SessionSignals) -> SessionState {
        guard s.processAlive else { return .idle }

        if isBusyStatus(s.reportedStatus) { return .busy }
        if isWaitingStatus(s.reportedStatus) { return .waiting }

        if let w = s.lastWrite, s.now.timeIntervalSince(w) < recentWriteWindow {
            return .busy
        }
        guard let entry = s.lastEntry else { return .waiting }
        switch entry.kind {
        case .assistant(let stop, let hasToolUse):
            if hasToolUse || stop == "tool_use" { return .busy }
            if stop == nil { return .busy }
            return .waiting // end_turn, stop_sequence, max_tokens, refusal…
        case .user:
            return .busy
        }
    }
}

/// Reads the last user/assistant entry from the end of a transcript without
/// loading the whole file.
public enum TranscriptTail {
    public static func lastEntry(of url: URL, maxBytes: Int = 1 << 20) -> LastEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return lastEntry(in: data, droppingFirstLine: start > 0)
    }

    public static func lastEntry(in data: Data, droppingFirstLine: Bool = false) -> LastEntry? {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if droppingFirstLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "assistant" || type == "user",
                  obj["isSidechain"] as? Bool != true
            else { continue }
            let ts = (obj["timestamp"] as? String).flatMap(ISODate.parse)
            let message = obj["message"] as? [String: Any]
            let blocks = (message?["content"] as? [[String: Any]]) ?? []
            let blockTypes = blocks.compactMap { $0["type"] as? String }
            if type == "assistant" {
                return LastEntry(kind: .assistant(stopReason: message?["stop_reason"] as? String,
                                                  hasToolUse: blockTypes.contains("tool_use")), timestamp: ts)
            }
            if obj["isMeta"] as? Bool == true { continue }
            return LastEntry(kind: .user(isToolResult: blockTypes.contains("tool_result")), timestamp: ts)
        }
        return nil
    }
}
