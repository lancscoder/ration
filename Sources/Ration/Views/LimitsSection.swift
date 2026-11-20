import RationCore
import SwiftUI

struct LimitsSection: View {
    let state: AppState

    var body: some View {
        CollapsibleCard(section: .limits, prefs: state.prefs,
                        trailing: state.usage.plan.map { AnyView(PlanBadge(text: $0)) },
                        collapsedSummary: AnyView(summary)) {
            if let response = state.usage.response {
                if let s = response.session { LimitRow(limit: s, state: state) }
                if let w = response.weekly { LimitRow(limit: w, state: state) }
                ForEach(response.modelLimits) { LimitRow(limit: $0, state: state, compact: true) }
                if let extra = response.extraUsage { ExtraUsageRow(extra: extra) }
                if !response.breakdown.isEmpty { BreakdownLine(rows: response.breakdown) }
            } else {
                Text(state.statusMessage ?? "Loading usage…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        let r = state.usage.response
        let parts = [r?.session.map { "5h \(Fmt.percent($0.utilization))" }, r?.weekly.map { "W \(Fmt.percent($0.utilization))" }]
        return Text(parts.compactMap { $0 }.joined(separator: " · "))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

struct PlanBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }
}

struct LimitRow: View {
    let limit: LimitDisplay
    let state: AppState
    var compact = false

    var body: some View {
        let level = state.prefs.level(for: limit.utilization)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(compact ? .callout : .callout.weight(.medium))
                Spacer()
                Text(Fmt.percent(limit.utilization))
                    .font((compact ? Font.callout : .title3).weight(.semibold).monospacedDigit())
                    .foregroundStyle(level == .normal ? Color.primary : level.color)
            }
            UsageBar(fraction: limit.utilization / 100, color: level.color)
            if let reset = limit.resetsAt {
                Text(resetText(reset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.title)
        .accessibilityValue("\(Fmt.percent(limit.utilization)) used" + (limit.resetsAt.map { ". \(resetText($0))" } ?? ""))
    }

    private func resetText(_ reset: Date) -> String {
        let remaining = reset.timeIntervalSince(state.now)
        if remaining <= 0 { return "Reset due (awaiting refresh)" }
        return "Resets in \(Fmt.duration(remaining)) · \(Fmt.resetClock(reset, now: state.now))"
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Extra usage", systemImage: "creditcard")
                .font(.callout)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let used = extra.usedAmount, let limit = extra.limitAmount {
                    Text("\(extra.format(used)) of \(extra.format(limit))")
                        .font(.callout.monospacedDigit())
                } else if let used = extra.usedAmount {
                    Text(extra.format(used)).font(.callout.monospacedDigit())
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if extra.isEnabled == true { return "On" }
        if let reason = extra.disabledReason {
            return "Off · " + reason.replacingOccurrences(of: "_", with: " ")
        }
        return "Off"
    }
}

struct BreakdownLine: View {
    let rows: [BreakdownRow]
    var body: some View {
        let parts = rows.filter { $0.percent > 0 }.map { "\($0.displayName) \(Int($0.percent))%" }
        if !parts.isEmpty {
            Text("This week: " + parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
