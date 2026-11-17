import Foundation

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public mutating func add(_ o: TokenCounts) {
        input += o.input
        output += o.output
        cacheWrite += o.cacheWrite
        cacheRead += o.cacheRead
    }

    public func total(includingCacheReads: Bool) -> Int {
        input + output + cacheWrite + (includingCacheReads ? cacheRead : 0)
    }
}

public enum TokenRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, twoWeeks, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .twoWeeks: return "14 days"
        case .all: return "All"
        }
    }
}

public enum BucketGranularity: Sendable {
    case hour, day
    public var component: Calendar.Component { self == .hour ? .hour : .day }
}

public struct TokenBucket: Identifiable, Sendable, Equatable {
    public var start: Date
    public var model: String
    public var counts: TokenCounts
    public var id: String { "\(start.timeIntervalSince1970)|\(model)" }
}

public struct ModelTotals: Identifiable, Sendable, Equatable {
    public var model: String
    public var counts: TokenCounts
    public var messages: Int
    public var id: String { model }
}

public struct SessionTokenSummary: Sendable, Equatable {
    public var sessionId: String
    public var firstActivity: Date
    public var lastActivity: Date
    public var lastModel: String
    public var counts: TokenCounts
    public var messages: Int
}

/// Pure aggregation over deduplicated records. Calendar (and so time zone)
/// is injected, so day boundaries are testable.
public enum TokenAggregator {
    /// Start of the range, or nil for "everything".
    public static func rangeStart(_ range: TokenRange, now: Date, calendar: Calendar, historyDays: Int) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .twoWeeks: return calendar.date(byAdding: .day, value: -13, to: today)
        case .all: return historyDays > 0 ? calendar.date(byAdding: .day, value: -(historyDays - 1), to: today) : nil
        }
    }

    public static func granularity(for range: TokenRange) -> BucketGranularity {
        range == .today ? .hour : .day
    }

    public static func filter(_ records: [UsageRecord], range: TokenRange, now: Date, calendar: Calendar, historyDays: Int) -> ArraySlice<UsageRecord> {
        guard let start = rangeStart(range, now: now, calendar: calendar, historyDays: historyDays)?.timeIntervalSince1970 else {
            return records[...]
        }
        // Records are sorted by time: binary search the first in range.
        var lo = 0, hi = records.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if records[mid].time < start { lo = mid + 1 } else { hi = mid }
        }
        return records[lo...]
    }

    /// Per-bucket (hour for Today, day otherwise), per-model sums.
    public static func buckets(_ records: [UsageRecord], range: TokenRange, now: Date, calendar: Calendar, historyDays: Int) -> [TokenBucket] {
        let gran = granularity(for: range)
        var sums: [Date: [String: TokenCounts]] = [:]
        var cachedDayStart: (lo: Double, hi: Double, start: Date)?
        for r in filter(records, range: range, now: now, calendar: calendar, historyDays: historyDays) {
            let bucketStart: Date
            if gran == .day {
                if let c = cachedDayStart, r.time >= c.lo, r.time < c.hi {
                    bucketStart = c.start
                } else {
                    let start = calendar.startOfDay(for: r.date)
                    let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                    cachedDayStart = (start.timeIntervalSince1970, next.timeIntervalSince1970, start)
                    bucketStart = start
                }
            } else {
                bucketStart = calendar.dateInterval(of: .hour, for: r.date)?.start ?? r.date
            }
            sums[bucketStart, default: [:]][r.model, default: TokenCounts()].add(r.counts)
        }
        return sums
            .flatMap { start, models in models.map { TokenBucket(start: start, model: $0.key, counts: $0.value) } }
            .sorted { ($0.start, $0.model) < ($1.start, $1.model) }
    }

    public static func totalsByModel(_ records: [UsageRecord], range: TokenRange, now: Date, calendar: Calendar, historyDays: Int) -> [ModelTotals] {
        var sums: [String: ModelTotals] = [:]
        for r in filter(records, range: range, now: now, calendar: calendar, historyDays: historyDays) {
            sums[r.model, default: ModelTotals(model: r.model, counts: TokenCounts(), messages: 0)].counts.add(r.counts)
            sums[r.model]!.messages += 1
        }
        return sums.values.sorted { $0.counts.total(includingCacheReads: true) > $1.counts.total(includingCacheReads: true) }
    }

    public static func sessions(_ records: [UsageRecord]) -> [String: SessionTokenSummary] {
        var out: [String: SessionTokenSummary] = [:]
        for r in records where !r.sessionId.isEmpty {
            if var s = out[r.sessionId] {
                s.counts.add(r.counts)
                s.messages += 1
                if r.date >= s.lastActivity { s.lastActivity = r.date; s.lastModel = r.model }
                if r.date < s.firstActivity { s.firstActivity = r.date }
                out[r.sessionId] = s
            } else {
                out[r.sessionId] = SessionTokenSummary(sessionId: r.sessionId, firstActivity: r.date, lastActivity: r.date,
                                                       lastModel: r.model, counts: r.counts, messages: 1)
            }
        }
        return out
    }
}

/// `claude-opus-5-5` → `Opus 5.5`; `claude-3-5-sonnet-20241022` → `Sonnet 3.5`.
public enum ModelName {
    public static func display(_ raw: String) -> String {
        var parts = raw.lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && Int($0) != nil } // date suffix
        let family = parts.first { Int($0) == nil }
        let version = parts.filter { Int($0) != nil && $0.count <= 2 }
        guard let family else { return raw }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    public static func family(_ raw: String) -> String {
        let lower = raw.lowercased()
        for f in ["opus", "sonnet", "haiku", "fable"] where lower.contains(f) { return f }
        return "other"
    }
}
