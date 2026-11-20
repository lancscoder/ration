import Foundation
import Testing
@testable import RationCore

@Suite("Burn rate and forecast")
struct BurnRateTests {
    let now = date("2026-11-17T15:00:00Z")
    var reset: Date { now.addingTimeInterval(3 * 3600) }

    func sample(minutesAgo: Double, pct: Double, reset: Date? = nil) -> QuotaSample {
        QuotaSample(t: now.addingTimeInterval(-minutesAgo * 60), fiveHour: pct, fiveHourResetsAt: reset ?? self.reset)
    }

    @Test func linearBurn() throws {
        // 10% per 30 min = 20%/h
        let samples = [sample(minutesAgo: 30, pct: 10), sample(minutesAgo: 15, pct: 15), sample(minutesAgo: 0, pct: 20)]
        let rate = try #require(BurnRateCalculator.sessionRate(samples: samples, now: now, resetsAt: reset))
        #expect(abs(rate.percentPerHour - 20) < 1e-9)
        #expect(rate.sampleCount == 3)
        #expect(rate.span == 1800)
    }

    @Test func weeklyPaceOverTheLastDay() throws {
        let weekReset = now.addingTimeInterval(2 * 24 * 3600)
        func w(_ hoursAgo: Double, _ pct: Double, reset: Date? = nil) -> QuotaSample {
            QuotaSample(t: now.addingTimeInterval(-hoursAgo * 3600), fiveHour: nil, fiveHourResetsAt: nil,
                        weekly: pct, weeklyResetsAt: reset ?? weekReset)
        }
        // 1%/h across the last day; a 30-hour-old sample and a previous week's sample are ignored.
        let samples = [w(30, 0), w(20, 40, reset: now.addingTimeInterval(-3600)), w(20, 30), w(10, 40), w(0, 50)]
        let rate = try #require(BurnRateCalculator.weeklyRate(samples: samples, now: now, resetsAt: weekReset))
        #expect(abs(rate.percentPerHour - 1) < 1e-9)
        #expect(rate.sampleCount == 3)

        // 50% left at 1%/h = 50 h, but the week resets in 48 h → safe, ~98% at reset.
        #expect(BurnRateCalculator.forecast(current: 50, rate: rate, resetsAt: weekReset, now: now)
                == .safeUntilReset(projectedAtReset: 98))
        // Under two hours of data isn't enough.
        #expect(BurnRateCalculator.weeklyRate(samples: [w(1, 49), w(0, 50)], now: now, resetsAt: weekReset) == nil)
    }

    @Test func needsMinimumSpan() {
        let samples = [sample(minutesAgo: 5, pct: 10), sample(minutesAgo: 0, pct: 12)]
        #expect(BurnRateCalculator.sessionRate(samples: samples, now: now, resetsAt: reset) == nil)
        #expect(BurnRateCalculator.sessionRate(samples: [sample(minutesAgo: 0, pct: 1)], now: now, resetsAt: reset) == nil)
    }

    @Test func ignoresOldSamplesAndPreviousWindow() throws {
        let previousReset = now.addingTimeInterval(-2 * 3600)
        let samples = [
            sample(minutesAgo: 120, pct: 0),            // outside lookback
            sample(minutesAgo: 50, pct: 95, reset: previousReset), // previous window
            sample(minutesAgo: 40, pct: 2),
            sample(minutesAgo: 0, pct: 6),
        ]
        let rate = try #require(BurnRateCalculator.sessionRate(samples: samples, now: now, resetsAt: reset))
        #expect(abs(rate.percentPerHour - 6) < 1e-9)
        #expect(rate.sampleCount == 2)
    }

    @Test func toleratesResetJitter() throws {
        let jittered = reset.addingTimeInterval(0.0002)
        let samples = [sample(minutesAgo: 30, pct: 10, reset: jittered), sample(minutesAgo: 0, pct: 11)]
        #expect(BurnRateCalculator.sessionRate(samples: samples, now: now, resetsAt: reset) != nil)
    }

    @Test func neverNegative() throws {
        let samples = [sample(minutesAgo: 30, pct: 10), sample(minutesAgo: 0, pct: 9)]
        let rate = try #require(BurnRateCalculator.sessionRate(samples: samples, now: now, resetsAt: reset))
        #expect(rate.percentPerHour == 0)
    }

    @Test func forecastHitsLimitBeforeReset() {
        let rate = BurnRate(percentPerHour: 40, span: 1800, sampleCount: 3)
        // 60% left at 40%/h = 1.5h; reset is in 3h.
        let f = BurnRateCalculator.forecast(current: 40, rate: rate, resetsAt: reset, now: now)
        #expect(f == .limitIn(5400))
        #expect(f.text == "At this rate: limit in ~1h30m")
    }

    @Test func forecastSafeUntilReset() {
        let rate = BurnRate(percentPerHour: 10, span: 1800, sampleCount: 3)
        // 3h * 10%/h = +30 → 70% at reset.
        let f = BurnRateCalculator.forecast(current: 40, rate: rate, resetsAt: reset, now: now)
        #expect(f == .safeUntilReset(projectedAtReset: 70))
        #expect(f.text == "Won't hit limit before reset (~70% at reset)")
    }

    @Test func forecastEdgeCases() {
        let rate = BurnRate(percentPerHour: 0.01, span: 1800, sampleCount: 3)
        #expect(BurnRateCalculator.forecast(current: 40, rate: nil, resetsAt: reset, now: now) == .collecting)
        #expect(BurnRateCalculator.forecast(current: 40, rate: rate, resetsAt: reset, now: now) == .idle)
        #expect(BurnRateCalculator.forecast(current: 100, rate: rate, resetsAt: reset, now: now) == .atLimit)
        // No reset known: always a time-to-limit.
        let fast = BurnRate(percentPerHour: 50, span: 1800, sampleCount: 3)
        #expect(BurnRateCalculator.forecast(current: 50, rate: fast, resetsAt: nil, now: now) == .limitIn(3600))
    }

    @Test func durationFormatting() {
        #expect(Fmt.duration(30) == "<1m")
        #expect(Fmt.duration(45 * 60) == "45m")
        #expect(Fmt.duration(72 * 60) == "1h12m")
        #expect(Fmt.duration(2 * 86400 + 3 * 3600 + 100) == "2d3h")
        #expect(Fmt.tokens(1_234_567) == "1.2M")
        #expect(Fmt.tokens(950) == "950")
    }
}
