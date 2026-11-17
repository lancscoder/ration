import Foundation

/// One deduplicated assistant API response from a Claude Code session log.
/// Short coding keys keep the on-disk cache compact.
public struct UsageRecord: Codable, Sendable, Equatable {
    /// Dedup key: `message.id|requestId`.
    public var key: String
    /// Epoch seconds.
    public var time: Double
    public var model: String
    public var sessionId: String
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    enum CodingKeys: String, CodingKey {
        case key = "k", time = "t", model = "m", sessionId = "s", input = "i", output = "o", cacheWrite = "w", cacheRead = "r"
    }

    public init(key: String, time: Double, model: String, sessionId: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        self.key = key
        self.time = time
        self.model = model
        self.sessionId = sessionId
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var date: Date { Date(timeIntervalSince1970: time) }
    public var counts: TokenCounts { TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead) }
}

/// Result of parsing one line: the usage record plus line-level metadata.
public struct ParsedLine: Sendable, Equatable {
    public var record: UsageRecord
    public var cwd: String?
}

/// Parses Claude Code JSONL lines. Pure and stateless.
public enum LogParser {
    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var sessionId: String?
        var cwd: String?
        var requestId: String?
        var uuid: String?
        var message: Message?
    }
    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }
    private struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?
    }

    private static let assistantNeedle = Array(#""assistant""#.utf8)
    private static let usageNeedle = Array(#""usage""#.utf8)

    /// Returns a record for assistant entries that carry usage; `nil` for
    /// everything else (user turns, attachments, malformed JSON, synthetic messages).
    public static func parse(line: UnsafeRawBufferPointer, decoder: JSONDecoder = JSONDecoder()) -> ParsedLine? {
        guard contains(line, assistantNeedle), contains(line, usageNeedle) else { return nil }
        guard let decoded = try? decoder.decode(Line.self, from: Data(line)) else { return nil }
        return make(decoded)
    }

    public static func parse(line: String) -> ParsedLine? {
        var s = line
        return s.withUTF8 { parse(line: UnsafeRawBufferPointer($0)) }
    }

    private static func make(_ l: Line) -> ParsedLine? {
        guard l.type == "assistant",
              let msg = l.message, let usage = msg.usage,
              let model = msg.model, !model.isEmpty, !model.hasPrefix("<"), // "<synthetic>"
              let ts = l.timestamp, let date = ISODate.parse(ts)
        else { return nil }
        guard let id = msg.id ?? l.uuid else { return nil }
        let key = id + "|" + (l.requestId ?? "")
        let record = UsageRecord(
            key: key,
            time: date.timeIntervalSince1970,
            model: model,
            sessionId: l.sessionId ?? "",
            input: max(0, usage.input_tokens ?? 0),
            output: max(0, usage.output_tokens ?? 0),
            cacheWrite: max(0, usage.cache_creation_input_tokens ?? 0),
            cacheRead: max(0, usage.cache_read_input_tokens ?? 0)
        )
        return ParsedLine(record: record, cwd: l.cwd)
    }

    /// Splits `buffer` into complete lines (terminated by `\n`) and parses each.
    /// Returns the parsed lines and the number of bytes consumed; a trailing
    /// partial line is left for the next incremental read.
    public static func parseChunk(_ buffer: UnsafeRawBufferPointer) -> (lines: [ParsedLine], consumed: Int) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return ([], 0) }
        let decoder = JSONDecoder()
        var out: [ParsedLine] = []
        var start = 0
        while start < buffer.count {
            guard let nl = memchr(base + start, 0x0A, buffer.count - start) else { break }
            let end = base.distance(to: UnsafeRawPointer(nl))
            if end > start, let parsed = parse(line: UnsafeRawBufferPointer(rebasing: buffer[start..<end]), decoder: decoder) {
                out.append(parsed)
            }
            start = end + 1
        }
        return (out, start)
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(base, haystack.count, n.baseAddress!, n.count) != nil }
    }
}

/// Streamed responses are written as one line per content block, all with the
/// same `message.id` + `requestId`; resumed sessions also copy earlier
/// messages into the new file. Keep one record per key (largest `output`,
/// as in rodrigondec's collector) across all files.
public enum UsageDeduplicator {
    public static func merge<S: Sequence>(_ lists: S) -> [UsageRecord] where S.Element == [UsageRecord] {
        var byKey: [String: UsageRecord] = [:]
        for list in lists {
            for r in list {
                if let existing = byKey[r.key] {
                    if r.output > existing.output { byKey[r.key] = r }
                } else {
                    byKey[r.key] = r
                }
            }
        }
        return byKey.values.sorted { $0.time != $1.time ? $0.time < $1.time : $0.key < $1.key }
    }
}
