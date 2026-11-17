import Charts
import ClaudeBarCore
import SwiftUI

struct BurnRateSection: View {
    let state: AppState

    var body: some View {
        if let session = state.usage.response?.session {
            let rate = BurnRateCalculator.sessionRate(samples: state.usage.samples, now: state.now, resetsAt: session.resetsAt)
            let forecast = BurnRateCalculator.forecast(current: session.utilization, rate: rate, resetsAt: session.resetsAt, now: state.now)
            Card {
                SectionHeader("Burn rate", systemImage: "flame",
                              trailing: rate.map { AnyView(Text(String(format: "%.1f%%/h", $0.percentPerHour))
                                  .font(.callout.weight(.semibold).monospacedDigit())) })
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
        }
    }
}
