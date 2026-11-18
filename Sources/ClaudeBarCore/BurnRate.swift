import Foundation

/// Rate of quota consumption derived from successive quota samples.
public struct BurnRate: Sendable, Equatable {
    /// Percentage points of the window consumed per hour.
    public var percentPerHour: Double
    /// Time span covered by the samples used.
    public var span: TimeInterval
    public var sampleCount: Int
}

public enum Forecast: Sendable, Equatable {
    /// Not enough samples in the current window yet.
    case collecting
    /// Already at (or over) 100%.
    case atLimit
    /// Usage is flat.
    case idle
    /// At the current rate the limit is reached after this interval, before the reset.
    case limitIn(TimeInterval)
    /// The window resets before the limit would be reached; projected % at reset.
    case safeUntilReset(projectedAtReset: Double)

    public var text: String {
        switch self {
        case .collecting: return "Collecting samples to estimate burn rate…"
        case .atLimit: return "Limit reached"
        case .idle: return "Not burning right now"
        case .limitIn(let t): return "At this rate: limit in ~\(Fmt.duration(t))"
        case .safeUntilReset(let p): return "Won't hit limit before reset (~\(Int(p.rounded()))% at reset)"
        }
    }
}

public enum BurnRateCalculator {
    /// Window length of the session limit.
    public static let sessionWindow: TimeInterval = 5 * 3600
    /// Window length of the weekly limit.
    public static let weeklyWindow: TimeInterval = 7 * 24 * 3600

    /// Burn rate of the 5-hour window over the last `lookback` seconds.
    ///
    /// Only samples from the *current* window count (same `resets_at`, give or
    /// take jitter), so a reset never shows up as negative burn. The slope is a
    /// least-squares fit, which smooths the integer steps the endpoint reports.
    public static func sessionRate(samples: [QuotaSample],
                                   now: Date,
                                   resetsAt: Date?,
                                   lookback: TimeInterval = 3600,
                                   minimumSpan: TimeInterval = 15 * 60) -> BurnRate? {
        rate(samples: samples, value: { ($0.fiveHour, $0.fiveHourResetsAt) }, window: sessionWindow,
             now: now, resetsAt: resetsAt, lookback: lookback, minimumSpan: minimumSpan)
    }

    /// Pace of the weekly limit over the last day. A long lookback is deliberate:
    /// it averages over breaks and nights, which is what matters for a 7-day window.
    public static func weeklyRate(samples: [QuotaSample],
                                  now: Date,
                                  resetsAt: Date?,
                                  lookback: TimeInterval = 24 * 3600,
                                  minimumSpan: TimeInterval = 2 * 3600) -> BurnRate? {
        rate(samples: samples, value: { ($0.weekly, $0.weeklyResetsAt) }, window: weeklyWindow,
             now: now, resetsAt: resetsAt, lookback: lookback, minimumSpan: minimumSpan)
    }

    private static func rate(samples: [QuotaSample], value: (QuotaSample) -> (Double?, Date?), window: TimeInterval,
                             now: Date, resetsAt: Date?, lookback: TimeInterval, minimumSpan: TimeInterval) -> BurnRate? {
        let windowStart = resetsAt.map { $0.addingTimeInterval(-window) }
        let points: [(Double, Double)] = samples.compactMap { s in
            let (pct, sampleReset) = value(s)
            guard let pct, s.t <= now, now.timeIntervalSince(s.t) <= lookback else { return nil }
            if let resetsAt {
                guard let sr = sampleReset, abs(sr.timeIntervalSince(resetsAt)) < 120 else { return nil }
            }
            if let windowStart, s.t < windowStart { return nil }
            return (s.t.timeIntervalSince(now) / 3600, pct)
        }
        guard points.count >= 2,
              let first = points.map(\.0).min(), let last = points.map(\.0).max(),
              (last - first) * 3600 >= minimumSpan else { return nil }

        let n = Double(points.count)
        let mx = points.map(\.0).reduce(0, +) / n
        let my = points.map(\.1).reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in points {
            num += (x - mx) * (y - my)
            den += (x - mx) * (x - mx)
        }
        guard den > 0 else { return nil }
        return BurnRate(percentPerHour: max(0, num / den), span: (last - first) * 3600, sampleCount: points.count)
    }

    public static func forecast(current: Double, rate: BurnRate?, resetsAt: Date?, now: Date,
                                idleThreshold: Double = 0.1) -> Forecast {
        if current >= 100 { return .atLimit }
        guard let rate else { return .collecting }
        if rate.percentPerHour < idleThreshold { return .idle }
        let hoursToLimit = (100 - current) / rate.percentPerHour
        let secondsToLimit = hoursToLimit * 3600
        if let resetsAt {
            let untilReset = resetsAt.timeIntervalSince(now)
            if secondsToLimit >= untilReset {
                let projected = current + rate.percentPerHour * max(0, untilReset) / 3600
                return .safeUntilReset(projectedAtReset: min(100, projected))
            }
        }
        return .limitIn(secondsToLimit)
    }
}
