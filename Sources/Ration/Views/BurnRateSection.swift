import Charts
import RationCore
import SwiftUI

struct BurnRateSection: View {
    let state: AppState

    var body: some View {
        if let session = state.usage.response?.session {
            let rate = BurnRateCalculator.sessionRate(samples: state.usage.samples, now: state.now, resetsAt: session.resetsAt)
            let forecast = BurnRateCalculator.forecast(current: session.utilization, rate: rate, resetsAt: session.resetsAt, now: state.now)
            let rateText = rate.map { AnyView(Text(String(format: "%.1f%%/h", $0.percentPerHour))
                .font(.callout.weight(.semibold).monospacedDigit())) }
            CollapsibleCard(section: .burnRate, prefs: state.prefs, trailing: rateText, collapsedSummary: rateText) {
                HStack(spacing: 6) {
                    Image(systemName: icon(forecast))
                        .foregroundStyle(color(forecast))
                    Text(forecast.text)
                        .font(.callout)
                }
                if let rate {
                    Text("From \(rate.sampleCount) samples over the last \(Fmt.duration(rate.span)) of this window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SessionSparkline(samples: windowSamples(session), resetsAt: session.resetsAt)
                if let weekly = state.usage.response?.weekly {
                    WeeklyPaceRow(weekly: weekly, samples: state.usage.samples, now: state.now)
                }
            }
        }
    }

    private func windowSamples(_ session: LimitDisplay) -> [QuotaSample] {
        guard let reset = session.resetsAt else { return [] }
        let start = reset.addingTimeInterval(-BurnRateCalculator.sessionWindow)
        return state.usage.samples.filter { s in
            guard s.fiveHour != nil, s.t >= start, let r = s.fiveHourResetsAt else { return false }
            return abs(r.timeIntervalSince(reset)) < 120
        }
    }

    private func icon(_ f: Forecast) -> String {
        switch f {
        case .limitIn, .atLimit: return "exclamationmark.triangle.fill"
        case .safeUntilReset, .idle: return "checkmark.circle.fill"
        case .collecting: return "hourglass"
        }
    }

    private func color(_ f: Forecast) -> Color {
        switch f {
        case .limitIn, .atLimit: return .orange
        case .safeUntilReset, .idle: return .green
        case .collecting: return .secondary
        }
    }
}

/// Weekly limit pace from the last day of samples, e.g. "Weekly: on pace for ~80% by Thu 17:00".
struct WeeklyPaceRow: View {
    let weekly: LimitDisplay
    let samples: [QuotaSample]
    let now: Date

    var body: some View {
        let rate = BurnRateCalculator.weeklyRate(samples: samples, now: now, resetsAt: weekly.resetsAt)
        let forecast = BurnRateCalculator.forecast(current: weekly.utilization, rate: rate, resetsAt: weekly.resetsAt, now: now)
        Divider()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon(forecast)).foregroundStyle(color(forecast))
            VStack(alignment: .leading, spacing: 2) {
                Text(text(forecast)).font(.callout)
                if let rate {
                    Text(String(format: "Weekly pace %.1f%%/h over the last %@", rate.percentPerHour, Fmt.duration(rate.span)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func text(_ f: Forecast) -> String {
        switch f {
        case .collecting: return "Weekly: collecting samples (needs ~2h)"
        case .atLimit: return "Weekly limit reached"
        case .idle: return "Weekly: not burning right now"
        case .limitIn(let t): return "Weekly limit at this pace: ~\(Fmt.resetClock(now.addingTimeInterval(t), now: now))"
        case .safeUntilReset(let p):
            let reset = weekly.resetsAt.map { " by \(Fmt.resetClock($0, now: now))" } ?? ""
            return "Weekly: on pace for ~\(Int(p.rounded()))%\(reset)"
        }
    }

    private func icon(_ f: Forecast) -> String {
        switch f {
        case .limitIn, .atLimit: return "exclamationmark.triangle.fill"
        case .safeUntilReset, .idle: return "calendar"
        case .collecting: return "hourglass"
        }
    }

    private func color(_ f: Forecast) -> Color {
        switch f {
        case .limitIn, .atLimit: return .orange
        case .safeUntilReset, .idle: return .secondary
        case .collecting: return .secondary
        }
    }
}

/// Utilisation over the current 5-hour window, from the stored quota samples.
struct SessionSparkline: View {
    let samples: [QuotaSample]
    let resetsAt: Date?

    var body: some View {
        if samples.count >= 2, let resetsAt {
            Chart(samples, id: \.t) { s in
                AreaMark(x: .value("Time", s.t), y: .value("Used", s.fiveHour ?? 0))
                    .foregroundStyle(Color.accentColor.opacity(0.15).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.t), y: .value("Used", s.fiveHour ?? 0))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: resetsAt.addingTimeInterval(-BurnRateCalculator.sessionWindow)...resetsAt)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.caption2) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 70)
            .accessibilityLabel("Session usage over the current 5-hour window")
        }
    }
}
