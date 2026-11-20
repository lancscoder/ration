import Foundation

/// Polling cadence for the rate-limited usage endpoint.
public struct BackoffPolicy: Sendable, Equatable {
    public static let minimumPollInterval: TimeInterval = 300
    public static let defaultPollInterval: TimeInterval = 300

    public var baseInterval: TimeInterval
    public var maxInterval: TimeInterval
    public private(set) var failures: Int = 0

    public init(baseInterval: TimeInterval = defaultPollInterval, maxInterval: TimeInterval = 3600) {
        self.baseInterval = Self.clamp(baseInterval)
        self.maxInterval = maxInterval
    }

    public static func clamp(_ interval: TimeInterval) -> TimeInterval {
        max(minimumPollInterval, interval)
    }

    /// Delay before the next normal poll.
    public var normalDelay: TimeInterval { baseInterval }

    public mutating func recordSuccess() { failures = 0 }

    /// Records a failure (429 or transient) and returns how long to wait.
    /// Exponential: base·2, base·4, … capped at `maxInterval`, but a server
    /// `Retry-After` longer than that is always honoured.
    @discardableResult
    public mutating func recordFailure(retryAfter: TimeInterval? = nil) -> TimeInterval {
        failures += 1
        let exponential = min(maxInterval, baseInterval * pow(2, Double(min(failures, 10))))
        return max(retryAfter ?? 0, exponential)
    }
}
