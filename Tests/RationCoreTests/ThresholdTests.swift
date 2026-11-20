import Foundation
import Testing
@testable import RationCore

@Suite("Notification thresholds")
struct ThresholdTests {
    let reset = date("2026-11-17T19:10:00Z")

    func limit(_ pct: Double, reset: Date? = nil, id: String = "five_hour") -> LimitDisplay {
        LimitDisplay(id: id, kind: .session, title: "Session (5h)", utilization: pct, resetsAt: reset ?? self.reset)
    }

    @Test func parsesThresholdList() {
        #expect(ThresholdTracker.parseThresholds("75, 90") == [75, 90])
        #expect(ThresholdTracker.parseThresholds("90;75 75 abc 0 150") == [75, 90])
        #expect(ThresholdTracker.parseThresholds("") == [])
    }

    @Test func firesOncePerWindow() {
        var fired = Set<String>()
        var r = ThresholdTracker.evaluate(limits: [limit(50)], thresholds: [75, 90], fired: fired)
        #expect(r.alerts.isEmpty)
        fired = r.fired

        r = ThresholdTracker.evaluate(limits: [limit(76)], thresholds: [75, 90], fired: fired)
        #expect(r.alerts.map(\.threshold) == [75])
        fired = r.fired

        r = ThresholdTracker.evaluate(limits: [limit(80)], thresholds: [75, 90], fired: fired)
        #expect(r.alerts.isEmpty)
        fired = r.fired

        r = ThresholdTracker.evaluate(limits: [limit(91)], thresholds: [75, 90], fired: fired)
        #expect(r.alerts.map(\.threshold) == [90])
    }

    @Test func jumpOverSeveralThresholdsSendsOne() {
        let r = ThresholdTracker.evaluate(limits: [limit(95)], thresholds: [75, 90], fired: [])
        #expect(r.alerts.map(\.threshold) == [90])
        #expect(r.fired.count == 2)
        #expect(ThresholdTracker.evaluate(limits: [limit(95)], thresholds: [75, 90], fired: r.fired).alerts.isEmpty)
    }

    @Test func newWindowFiresAgainButJitterDoesNot() {
        let first = ThresholdTracker.evaluate(limits: [limit(80)], thresholds: [75], fired: [])
        let jittered = reset.addingTimeInterval(-0.2)
        #expect(ThresholdTracker.evaluate(limits: [limit(80, reset: jittered)], thresholds: [75], fired: first.fired).alerts.isEmpty)
        let next = reset.addingTimeInterval(5 * 3600)
        #expect(ThresholdTracker.evaluate(limits: [limit(80, reset: next)], thresholds: [75], fired: first.fired).alerts.count == 1)
    }

    @Test func limitsAreIndependent() {
        let r = ThresholdTracker.evaluate(limits: [limit(80), limit(92, id: "seven_day")], thresholds: [75, 90], fired: [])
        #expect(r.alerts.map(\.limitID) == ["five_hour", "seven_day"])
        #expect(r.alerts.map(\.threshold) == [75, 90])
    }

    @Test func resetRemindersOnlyForHeavilyUsedFutureWindows() {
        let now = reset.addingTimeInterval(-3600)
        let picked = ThresholdTracker.resetReminders(limits: [
            limit(92),                                              // yes
            limit(89, id: "seven_day"),                             // too low
            limit(95, reset: now.addingTimeInterval(30), id: "x"),  // resets within a minute
            LimitDisplay(id: "y", kind: .session, title: "No reset", utilization: 99, resetsAt: nil),
        ], now: now)
        #expect(picked.map(\.id) == ["five_hour"])
    }

    @Test func busyToWaitingTransitions() {
        func s(_ id: String, _ st: SessionState) -> SessionInfo {
            SessionInfo(sessionId: id, pid: 1, procStart: nil, cwd: "/x/\(id)", name: nil, state: st, lastActivity: nil, model: nil, tokens: nil)
        }
        let old = [s("a", .busy), s("b", .waiting), s("c", .busy)]
        let new = [s("a", .waiting), s("b", .waiting), s("c", .busy), s("d", .waiting)]
        #expect(ThresholdTracker.newlyWaiting(old: old, new: new).map(\.sessionId) == ["a"])
    }
}

@Suite("Fired threshold persistence")
struct FiredThresholdStoreTests {
    @Test func storesAPlainPropertyListArray() throws {
        let suite = "ration-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FiredThresholdStore(defaults: defaults)

        store.keys = Set((0..<100).map { "k\($0)" })
        // Regression: must be stored as a real [String] (plist), not a boxed ArraySlice.
        let raw = defaults.object(forKey: FiredThresholdStore.key)
        #expect(raw is [String])
        #expect(PropertyListSerialization.propertyList(raw as Any, isValidFor: .binary))
        #expect(store.keys.count == FiredThresholdStore.capacity)

        store.keys = ["a@1@75"]
        #expect(store.keys == ["a@1@75"])
    }
}
