import Foundation

/// What the menu bar label shows. The status dot is drawn separately by the app.
public struct MenuBarLabelOptions: Sendable, Equatable {
    public enum Limit: String, Sendable, CaseIterable { case session, weekly, both }

    public var limit: Limit
    public var showPercent: Bool
    public var showCountdown: Bool
    public var showResetTime: Bool

    public init(limit: Limit = .session, showPercent: Bool = true, showCountdown: Bool = true, showResetTime: Bool = false) {
        self.limit = limit
        self.showPercent = showPercent
        self.showCountdown = showCountdown
        self.showResetTime = showResetTime
    }

    public var showsAnyText: Bool { showPercent || showCountdown || showResetTime }
}

/// Builds the menu bar label text, e.g. `29% · 1h12m · 19:10` or `29% · 1h12m  W 51% · 2d1h`.
public enum MenuBarText {
    public static func compose(session: LimitDisplay?, weekly: LimitDisplay?, options: MenuBarLabelOptions,
                               now: Date, calendar: Calendar = .current) -> String {
        guard options.showsAnyText else { return "" }

        func part(_ limit: LimitDisplay?) -> String {
            guard let limit else { return "–" }
            var pieces: [String] = []
            if options.showPercent { pieces.append(Fmt.percent(limit.utilization)) }
            if let reset = limit.resetsAt, reset > now {
                if options.showCountdown { pieces.append(Fmt.duration(reset.timeIntervalSince(now))) }
                if options.showResetTime { pieces.append(Fmt.resetClock(reset, now: now, calendar: calendar)) }
            }
            return pieces.isEmpty ? "–" : pieces.joined(separator: " · ")
        }

        switch options.limit {
        case .session: return part(session)
        case .weekly: return "W " + part(weekly)
        case .both: return part(session) + "  W " + part(weekly)
        }
    }
}
