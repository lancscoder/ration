import Foundation
import Testing
@testable import RationCore

@Suite("Session state heuristic")
struct SessionStateTests {
    let now = date("2026-11-17T15:00:00Z")

    func resolve(alive: Bool = true, status: String? = nil, writtenSecondsAgo: Double? = nil, last: LastEntry.Kind? = nil) -> SessionState {
        SessionStateHeuristic.resolve(SessionSignals(
            processAlive: alive,
            reportedStatus: status,
            lastWrite: writtenSecondsAgo.map { now.addingTimeInterval(-$0) },
            lastEntry: last.map { LastEntry(kind: $0) },
            now: now))
    }

    @Test func deadProcessIsIdle() {
        #expect(resolve(alive: false, status: "busy", writtenSecondsAgo: 1) == .idle)
    }

    @Test func reportedStatusWins() {
        #expect(resolve(status: "busy", last: .assistant(stopReason: "end_turn", hasToolUse: false)) == .busy)
        #expect(resolve(status: "idle", writtenSecondsAgo: 1) == .waiting)
        #expect(resolve(status: "BUSY") == .busy)
    }

    @Test func unknownStatusFallsBackToTranscript() {
        #expect(resolve(status: "something-new", last: .assistant(stopReason: "end_turn", hasToolUse: false)) == .waiting)
    }

    @Test func recentWriteIsBusy() {
        #expect(resolve(writtenSecondsAgo: 3, last: .assistant(stopReason: "end_turn", hasToolUse: false)) == .busy)
        #expect(resolve(writtenSecondsAgo: 30, last: .assistant(stopReason: "end_turn", hasToolUse: false)) == .waiting)
    }

    @Test func pendingToolUseOrUnfinishedTurnIsBusy() {
        #expect(resolve(writtenSecondsAgo: 60, last: .assistant(stopReason: "tool_use", hasToolUse: true)) == .busy)
        #expect(resolve(writtenSecondsAgo: 60, last: .assistant(stopReason: nil, hasToolUse: false)) == .busy)
        #expect(resolve(writtenSecondsAgo: 60, last: .user(isToolResult: true)) == .busy)
        #expect(resolve(writtenSecondsAgo: 60, last: .user(isToolResult: false)) == .busy)
    }

    @Test func finishedTurnIsWaiting() {
        for stop in ["end_turn", "stop_sequence", "max_tokens"] {
            #expect(resolve(writtenSecondsAgo: 60, last: .assistant(stopReason: stop, hasToolUse: false)) == .waiting)
        }
        // Live process, nothing written yet.
        #expect(resolve() == .waiting)
    }

    @Test func transcriptTailFindsLastTurn() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-11-17T14:59:00Z"}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"x"}]},"timestamp":"2026-11-17T14:59:30Z"}"#,
            #"{"type":"ai-title","title":"x"}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use"}}"#,
        ]
        let entry = try #require(TranscriptTail.lastEntry(in: Data(lines.joined(separator: "\n").utf8)))
        #expect(entry.kind == .assistant(stopReason: "end_turn", hasToolUse: false))
        #expect(entry.timestamp == date("2026-11-17T14:59:30Z"))

        let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        #expect(TranscriptTail.lastEntry(in: Data((lines + [toolResult]).joined(separator: "\n").utf8))?.kind == .user(isToolResult: true))
        // A truncated first line (tail read) is dropped, not mis-parsed.
        #expect(TranscriptTail.lastEntry(in: Data(#"_end_turn"}}"#.utf8), droppingFirstLine: true) == nil)
    }

    @Test func ordering() {
        #expect([SessionState.idle, .busy, .waiting].sorted() == [.busy, .waiting, .idle])
    }
}

@Suite("Process and resume helpers")
struct ProcessHelperTests {
    @Test func procStartParsing() throws {
        let tz = TimeZone(identifier: "Europe/London")!
        let d = try #require(ProcessControl.parseProcStart("Fri Nov 13 12:51:28 2026", timeZone: tz))
        #expect(d == date("2026-11-13T12:51:28Z"))
        #expect(ProcessControl.parseProcStart("Tue Nov  3 09:05:01 2026", timeZone: tz) == date("2026-11-03T09:05:01Z"))
        #expect(ProcessControl.parseProcStart("garbage") == nil)
    }

    @Test func ownProcessIsAliveWithStartTime() throws {
        let pid = getpid()
        #expect(ProcessControl.isAlive(pid))
        let start = try #require(ProcessControl.startTime(pid))
        #expect(start <= Date() && start > Date().addingTimeInterval(-3600))
        #expect(!ProcessControl.isAlive(0))
        // A procStart from a different time means the PID was reused.
        #expect(!ProcessControl.matches(pid: pid, procStart: "Mon Jan  1 00:00:00 2001"))
        #expect(ProcessControl.matches(pid: pid, procStart: nil))
    }

    @Test func refusesToKillReusedPid() {
        #expect(throws: ProcessControl.TerminateError.pidReused) {
            try ProcessControl.terminate(pid: getpid(), procStart: "Mon Jan  1 00:00:00 2001")
        }
        #expect(throws: ProcessControl.TerminateError.notRunning) {
            try ProcessControl.terminate(pid: 0, procStart: nil)
        }
    }

    @Test func sessionIdValidation() {
        #expect(ResumeCommand.isSafeSessionId("5d3f9691-7564-47dd-8c71-bd76145d6f3b"))
        #expect(!ResumeCommand.isSafeSessionId("x; rm -rf ~"))
        #expect(!ResumeCommand.isSafeSessionId("$(id)"))
        #expect(!ResumeCommand.isSafeSessionId(""))
    }

    @Test func scriptQuotesPaths() throws {
        let script = try #require(ResumeCommand.script(cwd: "/Users/me/it's here", sessionId: "abc-123"))
        #expect(script.contains(#"cd -- '/Users/me/it'\''s here' || exit 1"#))
        #expect(script.contains("claude --resume abc-123"))
        #expect(ResumeCommand.script(cwd: "/tmp", sessionId: "a;b") == nil)
    }

    @Test func templateExpansion() {
        let s = ResumeCommand.expand(template: "wezterm start --cwd {cwd} -- zsh -lic {command}", cwd: "/a b", sessionId: "id-1", scriptPath: "/s")
        #expect(s == "wezterm start --cwd '/a b' -- zsh -lic 'claude --resume id-1'")
    }
}

@Suite("Session monitor")
struct SessionMonitorTests {
    @Test func listsLiveAndRecentSessions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ration-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let me = getpid()
        // Live: this test process stands in for a claude process.
        try #"{"pid":\#(me),"sessionId":"live-1","cwd":"/Users/me/code/alpha","status":"busy","updatedAt":1794928000000}"#
            .write(to: dir.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
        // Dead PID → ignored as live.
        try #"{"pid":999999,"sessionId":"dead-1","cwd":"/x","status":"busy"}"#
            .write(to: dir.appendingPathComponent("999999.json"), atomically: true, encoding: .utf8)
        // Unsafe session id → ignored.
        try #"{"pid":\#(me),"sessionId":"$(id)","status":"busy"}"#
            .write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        let now = Date()
        let summaries = [
            "recent-1": SessionTokenSummary(sessionId: "recent-1", firstActivity: now.addingTimeInterval(-7200), lastActivity: now.addingTimeInterval(-600),
                                            lastModel: "claude-opus-5-5", counts: TokenCounts(input: 1, output: 2), messages: 2),
            "old-1": SessionTokenSummary(sessionId: "old-1", firstActivity: now.addingTimeInterval(-90 * 3600), lastActivity: now.addingTimeInterval(-80 * 3600),
                                         lastModel: "claude-opus-5-5", counts: TokenCounts(), messages: 1),
        ]
        let sessions = await SessionMonitor(sessionDirs: [dir]).scan(
            sessionFiles: [:], sessionCwds: ["recent-1": "/Users/me/code/beta"], summaries: summaries, now: now)
        #expect(sessions.map(\.sessionId) == ["live-1", "recent-1"])
        #expect(sessions[0].state == .busy)
        #expect(sessions[0].pid == me)
        #expect(sessions[0].projectName == "alpha")
        #expect(sessions[1].state == .idle)
        #expect(sessions[1].projectName == "beta")
        #expect(sessions[1].model == "claude-opus-5-5")
    }
}
