import Foundation

public enum Fmt {
    /// Compact duration: `2d3h`, `1h12m`, `45m`, `<1m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let s = max(0, Int(seconds.rounded()))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    /// `3m ago`, `2h ago`, `just now`.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return "just now" }
        return "\(duration(s)) ago"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// `950`, `12.3K`, `4.5M`, `1.2B`.
    public static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    /// Wall-clock for a reset time: `19:10` today, `Thu 17:00` otherwise.
    public static func resetClock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jm")
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEEjm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMdjm")
        }
        return f.string(from: date)
    }
}
