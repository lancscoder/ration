import Foundation
import Testing
@testable import RationCore

@Suite("Menu bar label text")
struct MenuBarTextTests {
    let now = date("2026-11-17T17:58:00Z")
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    var session: LimitDisplay { LimitDisplay(id: "five_hour", kind: .session, title: "Session", utilization: 29.4, resetsAt: date("2026-11-17T19:10:00Z")) }
    var weekly: LimitDisplay { LimitDisplay(id: "seven_day", kind: .weekly, title: "Weekly", utilization: 51, resetsAt: date("2026-11-19T17:00:00Z")) }

    func text(_ o: MenuBarLabelOptions, session: LimitDisplay? = nil, weekly: LimitDisplay? = nil) -> String {
        MenuBarText.compose(session: session ?? self.session, weekly: weekly ?? self.weekly, options: o, now: now, calendar: calendar)
    }

    @Test func defaultIsPercentAndCountdown() {
        #expect(text(MenuBarLabelOptions()) == "29% · 1h12m")
    }

    @Test func eachPieceToggles() {
        #expect(text(MenuBarLabelOptions(showPercent: true, showCountdown: false)) == "29%")
        #expect(text(MenuBarLabelOptions(showPercent: false, showCountdown: true)) == "1h12m")
        #expect(text(MenuBarLabelOptions(showPercent: false, showCountdown: false, showResetTime: true)).contains("19:10"))
        let all = text(MenuBarLabelOptions(showPercent: true, showCountdown: true, showResetTime: true))
        #expect(all.hasPrefix("29% · 1h12m · ") && all.contains("19:10"))
    }

    @Test func nothingSelectedMeansIconOnly() {
        #expect(text(MenuBarLabelOptions(showPercent: false, showCountdown: false, showResetTime: false)) == "")
    }

    @Test func weeklyAndBoth() {
        #expect(text(MenuBarLabelOptions(limit: .weekly)) == "W 51% · 1d23h")
        #expect(text(MenuBarLabelOptions(limit: .both, showCountdown: false)) == "29%  W 51%")
    }

    @Test func missingDataShowsDash() {
        let o = MenuBarLabelOptions(limit: .both)
        #expect(MenuBarText.compose(session: nil, weekly: nil, options: o, now: now, calendar: calendar) == "–  W –")
        // Reset already passed: countdown dropped, percent kept.
        let stale = LimitDisplay(id: "five_hour", kind: .session, title: "S", utilization: 5, resetsAt: now.addingTimeInterval(-60))
        #expect(MenuBarText.compose(session: stale, weekly: nil, options: MenuBarLabelOptions(), now: now, calendar: calendar) == "5%")
    }
}
