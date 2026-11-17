import Foundation

public struct ThresholdAlert: Sendable, Equatable {
    public var limitID: String
    public var title: String
    public var threshold: Int
    public var utilization: Double
    public var resetsAt: Date?
}

/// Decides which usage-threshold notifications to send: each threshold fires
/// at most once per limit window (identified by its reset time, rounded to the
/// minute to absorb the endpoint's sub-second jitter).
public enum ThresholdTracker {
    public static func parseThresholds(_ text: String) -> [Int] {
        let values = text.split(whereSeparator: { ",; ".contains($0) }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return Array(Set(values.filter { (1...100).contains($0) })).sorted()
    }

    public static func key(limitID: String, resetsAt: Date?, threshold: Int) -> String {
        let window = resetsAt.map { String(Int(($0.timeIntervalSince1970 / 60).rounded())) } ?? "none"
        return "\(limitID)@\(window)@\(threshold)"
    }

    /// - Returns: one alert per limit (the highest newly crossed threshold) and
    ///   every key that should now be remembered as fired.
    public static func evaluate(limits: [LimitDisplay], thresholds: [Int], fired: Set<String>) -> (alerts: [ThresholdAlert], fired: Set<String>) {
        var fired = fired
        var alerts: [ThresholdAlert] = []
        for limit in limits {
            let crossed = thresholds.filter { limit.utilization >= Double($0) }
            let fresh = crossed.filter { !fired.contains(key(limitID: limit.id, resetsAt: limit.resetsAt, threshold: $0)) }
            for t in crossed { fired.insert(key(limitID: limit.id, resetsAt: limit.resetsAt, threshold: t)) }
            if let top = fresh.max() {
                alerts.append(ThresholdAlert(limitID: limit.id, title: limit.title, threshold: top, utilization: limit.utilization, resetsAt: limit.resetsAt))
            }
        }
        return (alerts, fired)
    }

    /// Sessions that went from busy to waiting between two scans.
    public static func newlyWaiting(old: [SessionInfo], new: [SessionInfo]) -> [SessionInfo] {
        let previous = Dictionary(old.map { ($0.sessionId, $0.state) }, uniquingKeysWith: { a, _ in a })
        return new.filter { $0.state == .waiting && previous[$0.sessionId] == .busy }
    }
}
