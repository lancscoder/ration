import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("JSONL parsing and dedup")
struct LogParserTests {
    func parseFixture() -> [ParsedLine] {
        let data = Fixture.data("session.jsonl")
        return data.withUnsafeBytes { LogParser.parseChunk($0).lines }
    }

    @Test func skipsNoiseAndMalformedLines() {
        let lines = parseFixture()
        // two msg_A lines (duplicates) + msg_B; synthetic, malformed, attachment, user skipped
        #expect(lines.count == 3)
        #expect(lines.map(\.record.key) == ["msg_A|req_1", "msg_A|req_1", "msg_B|req_2"])
        #expect(lines.first?.cwd == "/Users/me/code/alpha")
    }

    @Test func extractsUsage() throws {
        let r = try #require(parseFixture().last?.record)
        #expect(r.model == "claude-sonnet-5-5")
        #expect(r.input == 5 && r.output == 20 && r.cacheWrite == 0 && r.cacheRead == 1000)
        #expect(r.sessionId == "11111111-aaaa-bbbb-cccc-000000000001")
        #expect(r.date == date("2026-11-17T00:30:00Z"))
    }

    @Test func deduplicatesStreamedEntries() {
        let merged = UsageDeduplicator.merge([parseFixture().map(\.record)])
        #expect(merged.count == 2)
        #expect(merged.map(\.key) == ["msg_A|req_1", "msg_B|req_2"])
    }

    @Test func dedupAcrossFilesKeepsLargestOutput() {
        let a = UsageRecord(key: "k", time: 1, model: "m", sessionId: "s", input: 1, output: 5, cacheWrite: 0, cacheRead: 0)
        var b = a
        b.output = 9
        let merged = UsageDeduplicator.merge([[a], [b], [a]])
        #expect(merged.count == 1)
        #expect(merged[0].output == 9)
    }

    @Test func leavesPartialTrailingLine() {
        let text = #"{"type":"assistant","message":{"id":"x","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}},"requestId":"r","timestamp":"2026-11-17T00:00:00Z"}"# + "\n" + #"{"type":"assistant","mess"#
        let data = Data(text.utf8)
        let (lines, consumed) = data.withUnsafeBytes { LogParser.parseChunk($0) }
        #expect(lines.count == 1)
        #expect(consumed == text.firstIndex(of: "\n")!.utf16Offset(in: text) + 1)
    }

    @Test func fallsBackToUUIDWhenMessageIdMissing() {
        let line = #"{"type":"assistant","uuid":"u-9","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":3}},"timestamp":"2026-11-17T00:00:00Z"}"#
        #expect(LogParser.parse(line: line)?.record.key == "u-9|")
    }

    @Test func modelNames() {
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelName.display("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelName.display("claude-fable-5-2") == "Fable 5.2")
        #expect(ModelName.family("claude-3-5-sonnet-20241022") == "sonnet")
    }
}

@Suite("Incremental log store")
struct LogStoreTests {
    let sid = "11111111-aaaa-bbbb-cccc-000000000001"

    func makeTree() throws -> (root: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudebar-tests-\(UUID().uuidString)/projects")
        let project = root.appendingPathComponent("-Users-me-code-alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project)
    }

    func line(id: String, out: Int = 1, ts: String = "2026-11-17T10:00:00Z", session: String? = nil) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":\#(out),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"requestId":"r","timestamp":"\#(ts)","sessionId":"\#(session ?? sid)","cwd":"/Users/me/code/alpha"}"#
    }

    @Test func readsOnlyAppendedLines() async throws {
        let (root, project) = try makeTree()
        let file = project.appendingPathComponent("\(sid).jsonl")
        try (line(id: "m1") + "\n").write(to: file, atomically: false, encoding: .utf8)

        let store = LogStore(projectRoots: [root], cacheURL: nil)
        var snap = await store.refresh()
        #expect(snap.records.count == 1)
        #expect(snap.sessionCwds[sid] == "/Users/me/code/alpha")
        #expect(snap.sessionFiles[sid]?.lastPathComponent == "\(sid).jsonl")

        // Append a complete line and a partial one.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        let partial = line(id: "m3")
        try h.write(contentsOf: Data((line(id: "m2") + "\n" + partial.prefix(20)).utf8))
        snap = await store.refresh()
        #expect(snap.records.map(\.key) == ["m1|r", "m2|r"])

        // Complete the partial line.
        try h.write(contentsOf: Data((partial.dropFirst(20) + "\n").utf8))
        try h.close()
        snap = await store.refresh()
        #expect(snap.records.count == 3)
    }

    @Test func sessionFolderComesFromMainTranscriptNotSubagentWorktree() async throws {
        let (root, project) = try makeTree()
        try (line(id: "m1") + "\n").write(to: project.appendingPathComponent("\(sid).jsonl"), atomically: false, encoding: .utf8)
        let sub = project.appendingPathComponent("\(sid)/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // Several subagent logs so a lucky iteration order can't hide the bug.
        for i in 0..<8 {
            let worktree = line(id: "s\(i)").replacingOccurrences(of: "/Users/me/code/alpha", with: "/Users/me/code/alpha/.claude/worktrees/agent-\(i)")
            try (worktree + "\n").write(to: sub.appendingPathComponent("agent-\(i).jsonl"), atomically: false, encoding: .utf8)
        }
        // A session whose main transcript is gone still gets the subagent's folder.
        let orphan = "11111111-aaaa-bbbb-cccc-000000000002"
        let orphanSub = project.appendingPathComponent("\(orphan)/subagents")
        try FileManager.default.createDirectory(at: orphanSub, withIntermediateDirectories: true)
        try (line(id: "o1", session: orphan) + "\n").write(to: orphanSub.appendingPathComponent("agent-x.jsonl"), atomically: false, encoding: .utf8)

        let snap = await LogStore(projectRoots: [root], cacheURL: nil).refresh()
        #expect(snap.sessionCwds[sid] == "/Users/me/code/alpha")
        #expect(snap.sessionCwds[orphan] == "/Users/me/code/alpha")
        #expect(snap.sessionFiles[orphan] == nil)
    }

    @Test func rescansTruncatedFileAndDropsDeleted() async throws {
        let (root, project) = try makeTree()
        let file = project.appendingPathComponent("\(sid).jsonl")
        try ([line(id: "a"), line(id: "b")].joined(separator: "\n") + "\n").write(to: file, atomically: false, encoding: .utf8)
        let store = LogStore(projectRoots: [root], cacheURL: nil)
        #expect(await store.refresh().records.count == 2)

        try (line(id: "c") + "\n").write(to: file, atomically: false, encoding: .utf8)
        #expect(await store.refresh().records.map(\.key) == ["c|r"])

        try FileManager.default.removeItem(at: file)
        #expect(await store.refresh().records.isEmpty)
    }

    @Test func subagentLogsCountOnceAndAttributeToParent() async throws {
        let (root, project) = try makeTree()
        try (line(id: "p1") + "\n").write(to: project.appendingPathComponent("\(sid).jsonl"), atomically: false, encoding: .utf8)
        let sub = project.appendingPathComponent("\(sid)/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try ([line(id: "s1", out: 7), line(id: "p1")].joined(separator: "\n") + "\n")
            .write(to: sub.appendingPathComponent("agent-x.jsonl"), atomically: false, encoding: .utf8)

        let snap = await LogStore(projectRoots: [root], cacheURL: nil).refresh()
        #expect(snap.records.count == 2)
        #expect(Set(snap.records.map(\.sessionId)) == [sid])
        #expect(snap.sessionFiles.count == 1)
    }

    @Test func persistsAndReloadsCache() async throws {
        let (root, project) = try makeTree()
        try (line(id: "x") + "\n").write(to: project.appendingPathComponent("\(sid).jsonl"), atomically: false, encoding: .utf8)
        let cacheURL = root.deletingLastPathComponent().appendingPathComponent("tokens.json")
        let first = LogStore(projectRoots: [root], cacheURL: cacheURL, saveInterval: 0)
        _ = await first.refresh()
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        let second = LogStore(projectRoots: [root], cacheURL: cacheURL)
        #expect(await second.refresh().records.map(\.key) == ["x|r"])
    }
}

@Suite("Token aggregation")
struct TokenAggregationTests {
    func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    var records: [UsageRecord] {
        let data = Fixture.data("session.jsonl")
        return UsageDeduplicator.merge([data.withUnsafeBytes { LogParser.parseChunk($0).lines.map(\.record) }])
    }

    let now = date("2026-11-17T12:00:00Z")

    @Test(arguments: [
        // 23:30Z on the 16th and 00:30Z on the 17th
        ("UTC", 2, ["Opus 5.5": 16, "Sonnet 5.5": 17]),
        ("America/Los_Angeles", 1, ["Opus 5.5": 16, "Sonnet 5.5": 16]),
        ("Asia/Tokyo", 1, ["Opus 5.5": 17, "Sonnet 5.5": 17]),
    ])
    func groupsByLocalDay(tz: String, dayCount: Int, dayOfModel: [String: Int]) {
        let cal = calendar(tz)
        let buckets = TokenAggregator.buckets(records, range: .week, now: now, calendar: cal, historyDays: 90)
        #expect(Set(buckets.map(\.start)).count == dayCount)
        for b in buckets {
            #expect(cal.component(.day, from: b.start) == dayOfModel[ModelName.display(b.model)])
            #expect(cal.component(.hour, from: b.start) == 0)
        }
    }

    @Test func todayUsesHourBuckets() {
        let cal = calendar("UTC")
        let buckets = TokenAggregator.buckets(records, range: .today, now: now, calendar: cal, historyDays: 90)
        #expect(buckets.count == 1)
        #expect(buckets[0].start == date("2026-11-17T00:00:00Z"))
        #expect(buckets[0].model == "claude-sonnet-5-5")
    }

    @Test func totalsPerModel() {
        let totals = TokenAggregator.totalsByModel(records, range: .all, now: now, calendar: calendar("UTC"), historyDays: 90)
        let opus = totals.first { $0.model == "claude-opus-5-5" }
        #expect(opus?.counts == TokenCounts(input: 2, output: 10, cacheWrite: 100, cacheRead: 50))
        #expect(opus?.messages == 1)
        #expect(opus?.counts.total(includingCacheReads: false) == 112)
        #expect(opus?.counts.total(includingCacheReads: true) == 162)
    }

    @Test func rangeStarts() {
        let cal = calendar("UTC")
        #expect(TokenAggregator.rangeStart(.today, now: now, calendar: cal, historyDays: 90) == date("2026-11-17T00:00:00Z"))
        #expect(TokenAggregator.rangeStart(.week, now: now, calendar: cal, historyDays: 90) == date("2026-11-11T00:00:00Z"))
        #expect(TokenAggregator.rangeStart(.twoWeeks, now: now, calendar: cal, historyDays: 90) == date("2026-11-04T00:00:00Z"))
        #expect(TokenAggregator.rangeStart(.all, now: now, calendar: cal, historyDays: 0) == nil)
        // Outside the 1-day history window → excluded from "All".
        #expect(TokenAggregator.totalsByModel(records, range: .all, now: now, calendar: cal, historyDays: 1).map(\.model) == ["claude-sonnet-5-5"])
    }

    @Test func dstDayHas23Hours() {
        // Europe/London springs forward on 2026-03-29; both records belong to that local day.
        let cal = calendar("Europe/London")
        let recs = [
            UsageRecord(key: "a", time: date("2026-03-29T00:30:00Z").timeIntervalSince1970, model: "m", sessionId: "s", input: 1, output: 0, cacheWrite: 0, cacheRead: 0),
            UsageRecord(key: "b", time: date("2026-03-29T22:30:00Z").timeIntervalSince1970, model: "m", sessionId: "s", input: 1, output: 0, cacheWrite: 0, cacheRead: 0),
        ]
        let b = TokenAggregator.buckets(recs, range: .all, now: date("2026-03-30T12:00:00Z"), calendar: cal, historyDays: 0)
        #expect(b.count == 1)
        #expect(b[0].counts.input == 2)
    }

    @Test func sessionSummaries() {
        let s = TokenAggregator.sessions(records)
        let summary = s["11111111-aaaa-bbbb-cccc-000000000001"]
        #expect(summary?.messages == 2)
        #expect(summary?.lastModel == "claude-sonnet-5-5")
        #expect(summary?.lastActivity == date("2026-11-17T00:30:00Z"))
    }
}
