import Charts
import ClaudeBarCore
import SwiftUI

struct TokensSection: View {
    @Bindable var state: AppState

    var body: some View {
        let data = state.tokens
        let includeCache = state.showCacheReads
        Card {
            SectionHeader("Tokens", systemImage: "chart.bar.xaxis", trailing: AnyView(
                Toggle("Cache reads", isOn: $state.showCacheReads)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Include cache-read tokens (c)")
            ))
            Picker("Range", selection: $state.tokenRange) {
                ForEach(TokenRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !state.logsLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading Claude Code logs…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if data.buckets.isEmpty {
                Text("No Claude Code activity in this range.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                TokenChart(data: data, includeCache: includeCache)
                TotalsTable(totals: data.totals, includeCache: includeCache)
            }
        }
    }
}

enum ModelPalette {
    static func color(for model: String, index: Int) -> Color {
        let base: Color
        switch ModelName.family(model) {
        case "opus": base = Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude coral
        case "sonnet": base = Color(red: 0.33, green: 0.55, blue: 0.95)
        case "haiku": base = Color(red: 0.35, green: 0.75, blue: 0.50)
        case "fable": base = Color(red: 0.62, green: 0.45, blue: 0.90)
        default: base = .gray
        }
        return base.opacity(index == 0 ? 1 : max(0.45, 1 - Double(index) * 0.25))
    }

    /// Display names ordered by total (largest first) and a matching colour range.
    static func scale(for totals: [ModelTotals]) -> (domain: [String], range: [Color]) {
        var familyIndex: [String: Int] = [:]
        var domain: [String] = []
        var range: [Color] = []
        for t in totals {
            let name = ModelName.display(t.model)
            guard !domain.contains(name) else { continue }
            let fam = ModelName.family(t.model)
            let idx = familyIndex[fam, default: 0]
            familyIndex[fam] = idx + 1
            domain.append(name)
            range.append(color(for: t.model, index: idx))
        }
        return (domain, range)
    }
}

struct TokenChart: View {
    let data: TokenViewData
    let includeCache: Bool

    var body: some View {
        let scale = ModelPalette.scale(for: data.totals)
        Chart(data.buckets) { b in
            BarMark(
                x: .value("Time", b.start, unit: data.granularity.component),
                y: .value("Tokens", b.counts.total(includingCacheReads: includeCache))
            )
            .foregroundStyle(by: .value("Model", ModelName.display(b.model)))
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { Text(Fmt.tokens(v.as(Int.self) ?? 0)).font(.caption2) }
            }
        }
        .chartXAxis {
            if data.granularity == .hour {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 6)
        .frame(height: 160)
    }

    /// Full range on the x axis, including empty days.
    private var xDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date()
        if data.granularity == .hour {
            let start = cal.startOfDay(for: now)
            return start...cal.date(byAdding: .day, value: 1, to: start)!
        }
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let first = data.buckets.map(\.start).min() ?? end
        let start: Date
        switch data.range {
        case .week: start = cal.date(byAdding: .day, value: -7, to: end)!
        case .twoWeeks: start = cal.date(byAdding: .day, value: -14, to: end)!
        default: start = first
        }
        return min(start, first)...end
    }
}

struct TotalsTable: View {
    let totals: [ModelTotals]
    let includeCache: Bool

    var body: some View {
        let scale = ModelPalette.scale(for: totals)
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("Model").gridColumnAlignment(.leading)
                Text("Input")
                Text("Output")
                Text("Cache W")
                Text("Cache R")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(totals) { t in
                let name = ModelName.display(t.model)
                GridRow {
                    HStack(spacing: 5) {
                        Circle().fill(scale.range[scale.domain.firstIndex(of: name) ?? 0]).frame(width: 7, height: 7)
                        Text(name).lineLimit(1)
                    }
                    .gridColumnAlignment(.leading)
                    Text(Fmt.tokens(t.counts.input))
                    Text(Fmt.tokens(t.counts.output))
                    Text(Fmt.tokens(t.counts.cacheWrite))
                    Text(Fmt.tokens(t.counts.cacheRead)).foregroundStyle(includeCache ? .primary : .tertiary)
                }
                .font(.caption.monospacedDigit())
            }
            if totals.count > 1 {
                let sum = totals.reduce(into: TokenCounts()) { $0.add($1.counts) }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total").gridColumnAlignment(.leading)
                    Text(Fmt.tokens(sum.input))
                    Text(Fmt.tokens(sum.output))
                    Text(Fmt.tokens(sum.cacheWrite))
                    Text(Fmt.tokens(sum.cacheRead)).foregroundStyle(includeCache ? .primary : .tertiary)
                }
                .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let total = totals.reduce(0) { $0 + $1.counts.total(includingCacheReads: includeCache) }
        let messages = totals.reduce(0) { $0 + $1.messages }
        Text("\(Fmt.tokens(total)) tokens\(includeCache ? "" : " excl. cache reads") · \(messages) responses")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
