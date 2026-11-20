import Charts
import RationCore
import SwiftUI

struct TokensSection: View {
    @Bindable var state: AppState

    var body: some View {
        let data = state.tokens
        let includeCache = state.showCacheReads
        @Bindable var prefs = state.prefs
        CollapsibleCard(section: .tokens, prefs: state.prefs, trailing: AnyView(
            Toggle("Cache reads", isOn: $state.showCacheReads)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .help("Include cache-read tokens (c)")
        ), collapsedSummary: AnyView(collapsedSummary)) {
            HStack(spacing: 8) {
                Picker("Range", selection: $state.tokenRange) {
                    ForEach(TokenRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Chart style", selection: $prefs.tokenChartStyle) {
                    ForEach(TokenChartStyle.allCases) { style in
                        Image(systemName: style.systemImage)
                            .accessibilityLabel(style.title)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Switch between columns and a day list")
            }

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
                switch state.prefs.tokenChartStyle {
                case .columns:
                    TokenChart(data: data, includeCache: includeCache)
                case .dayList:
                    TokenDayList(data: data, includeCache: includeCache, historyDays: state.prefs.historyDays)
                }
                Picker("Group totals", selection: $prefs.tokenTableGrouping) {
                    ForEach(TokenTableGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.top, 2)
                switch state.prefs.tokenTableGrouping {
                case .model:
                    TotalsTable(rows: TotalsRow.models(data.totals), title: "Model", includeCache: includeCache)
                case .project:
                    TotalsTable(rows: TotalsRow.projects(data.projects), title: "Project", includeCache: includeCache)
                }
            }
        }
    }

    private var collapsedSummary: some View {
        let total = state.tokens.totals.reduce(0) { $0 + $1.counts.total(includingCacheReads: state.showCacheReads) }
        return Text("\(state.tokens.range.title): \(Fmt.tokens(total))")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// History as rows (newest first): label, stacked per-model bar on a track, total.
/// Same idea as rodrigondec/omarchy-claude-tokens. Empty days are kept so gaps show.
struct TokenDayList: View {
    let data: TokenViewData
    let includeCache: Bool
    let historyDays: Int

    private struct Row: Identifiable {
        var start: Date
        var segments: [(name: String, value: Int)]
        var total: Int
        var id: Date { start }
    }

    var body: some View {
        let scale = ModelPalette.scale(for: data.totals)
        let rows = makeRows(order: scale.domain)
        let maxTotal = max(1, rows.map(\.total).max() ?? 1)
        VStack(spacing: 5) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(label(row.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            HStack(spacing: 0) {
                                ForEach(row.segments, id: \.name) { seg in
                                    Rectangle()
                                        .fill(color(seg.name, scale))
                                        .frame(width: geo.size.width * CGFloat(seg.value) / CGFloat(maxTotal))
                                }
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .frame(height: 8)
                    Text(row.total == 0 ? "0" : Fmt.tokens(row.total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(row.total == 0 ? .tertiary : .primary)
                        .frame(width: 48, alignment: .trailing)
                }
                .help(tooltip(row))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(row.start))
                .accessibilityValue("\(Fmt.tokens(row.total)) tokens")
            }
        }
    }

    private func makeRows(order: [String]) -> [Row] {
        let cal = Calendar.current
        let now = Date()
        let comp = data.granularity.component
        var byStart: [Date: [String: Int]] = [:]
        for b in data.buckets {
            byStart[b.start, default: [:]][ModelName.display(b.model), default: 0] += b.counts.total(includingCacheReads: includeCache)
        }
        // Every slot in the range, so empty days/hours show as gaps.
        let last = cal.dateInterval(of: comp, for: now)?.start ?? now
        var first = TokenAggregator.rangeStart(data.range, now: now, calendar: cal, historyDays: historyDays) ?? last
        if data.range == .all, let earliest = byStart.keys.min() { first = max(first, earliest) }
        var slots: [Date] = []
        var cursor = first
        while cursor <= last, slots.count < 400 {
            slots.append(cursor)
            guard let next = cal.date(byAdding: comp, value: 1, to: cursor) else { break }
            cursor = next
        }
        return slots.reversed().map { start in
            let models = byStart[start] ?? [:]
            let segments: [(name: String, value: Int)] = order.compactMap { name in
                guard let v = models[name], v > 0 else { return nil }
                return (name: name, value: v)
            }
            return Row(start: start, segments: segments, total: segments.reduce(0) { $0 + $1.value })
        }
    }

    private func label(_ date: Date) -> String {
        let f = DateFormatter()
        if data.granularity == .hour {
            f.setLocalizedDateFormatFromTemplate("HH:mm")
        } else {
            f.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return f.string(from: date)
    }

    private func color(_ name: String, _ scale: (domain: [String], range: [Color])) -> Color {
        scale.domain.firstIndex(of: name).map { scale.range[$0] } ?? .gray
    }

    private func tooltip(_ row: Row) -> String {
        row.segments.map { "\($0.name): \(Fmt.tokens($0.value))" }.joined(separator: "\n")
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
        .accessibilityLabel("Tokens per \(data.granularity == .hour ? "hour" : "day") by model")
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

/// One row of the totals table: a model or a project.
struct TotalsRow: Identifiable {
    var id: String
    var name: String
    var detail: String?
    var color: Color?
    var counts: TokenCounts
    var messages: Int

    static func models(_ totals: [ModelTotals]) -> [TotalsRow] {
        let scale = ModelPalette.scale(for: totals)
        return totals.map { t in
            let name = ModelName.display(t.model)
            return TotalsRow(id: t.model, name: name, detail: t.model,
                             color: scale.range[scale.domain.firstIndex(of: name) ?? 0], counts: t.counts, messages: t.messages)
        }
    }

    /// The largest `limit` projects, the rest folded into one "Other" row.
    static func projects(_ totals: [ProjectTotals], limit: Int = 8) -> [TotalsRow] {
        let home = NSHomeDirectory()
        var rows = totals.prefix(limit).map { t in
            TotalsRow(id: t.path, name: t.name, detail: t.path.isEmpty ? nil : t.path.replacingOccurrences(of: home, with: "~"),
                      color: nil, counts: t.counts, messages: t.messages)
        }
        let rest = totals.dropFirst(limit)
        if !rest.isEmpty {
            let counts = rest.reduce(into: TokenCounts()) { $0.add($1.counts) }
            rows.append(TotalsRow(id: "__other", name: "Other (\(rest.count))", detail: rest.map(\.name).joined(separator: ", "),
                                  color: nil, counts: counts, messages: rest.reduce(0) { $0 + $1.messages }))
        }
        return rows
    }
}

struct TotalsTable: View {
    let rows: [TotalsRow]
    let title: String
    let includeCache: Bool

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
                Text("Input")
                Text("Output")
                Text("Cache W")
                Text("Cache R")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { row in
                GridRow {
                    HStack(spacing: 5) {
                        if let color = row.color {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                    }
                    .gridColumnAlignment(.leading)
                    Text(Fmt.tokens(row.counts.input))
                    Text(Fmt.tokens(row.counts.output))
                    Text(Fmt.tokens(row.counts.cacheWrite))
                    Text(Fmt.tokens(row.counts.cacheRead)).foregroundStyle(includeCache ? .primary : .tertiary)
                }
                .font(.caption.monospacedDigit())
                .help(row.detail ?? row.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.name)
                .accessibilityValue("\(Fmt.tokens(row.counts.input)) input, \(Fmt.tokens(row.counts.output)) output, "
                                    + "\(Fmt.tokens(row.counts.cacheWrite)) cache write, \(Fmt.tokens(row.counts.cacheRead)) cache read tokens")
            }
            if rows.count > 1 {
                let sum = rows.reduce(into: TokenCounts()) { $0.add($1.counts) }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total").gridColumnAlignment(.leading)
                    Text(Fmt.tokens(sum.input))
                    Text(Fmt.tokens(sum.output))
                    Text(Fmt.tokens(sum.cacheWrite))
                    Text(Fmt.tokens(sum.cacheRead)).foregroundStyle(includeCache ? .primary : .tertiary)
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let total = rows.reduce(0) { $0 + $1.counts.total(includingCacheReads: includeCache) }
        let messages = rows.reduce(0) { $0 + $1.messages }
        Text("\(Fmt.tokens(total)) tokens\(includeCache ? "" : " excl. cache reads") · \(messages) responses")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
