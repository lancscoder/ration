import ClaudeBarCore
import Foundation
import Observation

enum LabelFormat: String, CaseIterable, Identifiable {
    case session, weekly, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: return "5-hour session"
        case .weekly: return "Weekly"
        case .both: return "Both"
        }
    }
}

enum PanelSection: String, CaseIterable, Identifiable {
    case limits, burnRate, tokens, sessions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .limits: return "Limits"
        case .burnRate: return "Burn rate"
        case .tokens: return "Tokens"
        case .sessions: return "Sessions"
        }
    }
    var systemImage: String {
        switch self {
        case .limits: return "gauge.with.dots.needle.33percent"
        case .burnRate: return "flame"
        case .tokens: return "chart.bar.xaxis"
        case .sessions: return "terminal"
        }
    }
}

enum TokenChartStyle: String, CaseIterable, Identifiable {
    case columns, dayList
    var id: String { rawValue }
    var title: String { self == .columns ? "Columns" : "Day list" }
    var systemImage: String { self == .columns ? "chart.bar.fill" : "list.bullet.below.rectangle" }
}

/// User settings, persisted to `UserDefaults`.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var pollInterval: Int { didSet { defaults.set(pollInterval, forKey: "pollInterval") } }
    var warningThreshold: Int { didSet { defaults.set(warningThreshold, forKey: "warningThreshold") } }
    var criticalThreshold: Int { didSet { defaults.set(criticalThreshold, forKey: "criticalThreshold") } }
    var labelFormat: LabelFormat { didSet { defaults.set(labelFormat.rawValue, forKey: "labelFormat") } }
    var labelShowPercent: Bool { didSet { defaults.set(labelShowPercent, forKey: "labelShowPercent") } }
    var labelShowCountdown: Bool { didSet { defaults.set(labelShowCountdown, forKey: "labelShowCountdown") } }
    var labelShowResetTime: Bool { didSet { defaults.set(labelShowResetTime, forKey: "labelShowResetTime") } }
    var labelShowStatus: Bool { didSet { defaults.set(labelShowStatus, forKey: "labelShowStatus") } }

    var labelOptions: MenuBarLabelOptions {
        MenuBarLabelOptions(limit: MenuBarLabelOptions.Limit(rawValue: labelFormat.rawValue) ?? .session,
                            showPercent: labelShowPercent, showCountdown: labelShowCountdown, showResetTime: labelShowResetTime)
    }
    var historyDays: Int { didSet { defaults.set(historyDays, forKey: "historyDays") } }
    var hideCacheReadsByDefault: Bool { didSet { defaults.set(hideCacheReadsByDefault, forKey: "hideCacheReadsByDefault") } }
    /// Bundle ID of the terminal for Resume, or `TerminalCatalog.customID`.
    var terminal: String { didSet { defaults.set(terminal, forKey: "terminal") } }
    var customTerminalCommand: String { didSet { defaults.set(customTerminalCommand, forKey: "customTerminalCommand") } }
    var notifyUsage: Bool { didSet { defaults.set(notifyUsage, forKey: "notifyUsage") } }
    var notifyThresholds: String { didSet { defaults.set(notifyThresholds, forKey: "notifyThresholds") } }
    var notifyWaiting: Bool { didSet { defaults.set(notifyWaiting, forKey: "notifyWaiting") } }

    var hiddenSections: Set<String> { didSet { defaults.set(Array(hiddenSections).sorted(), forKey: "hiddenSections") } }
    var collapsedSections: Set<String> { didSet { defaults.set(Array(collapsedSections).sorted(), forKey: "collapsedSections") } }
    var tokenChartStyle: TokenChartStyle { didSet { defaults.set(tokenChartStyle.rawValue, forKey: "tokenChartStyle") } }

    func isVisible(_ section: PanelSection) -> Bool { !hiddenSections.contains(section.rawValue) }
    func setVisible(_ section: PanelSection, _ visible: Bool) {
        if visible { hiddenSections.remove(section.rawValue) } else { hiddenSections.insert(section.rawValue) }
    }
    func isCollapsed(_ section: PanelSection) -> Bool { collapsedSections.contains(section.rawValue) }
    func toggleCollapsed(_ section: PanelSection) {
        if isCollapsed(section) { collapsedSections.remove(section.rawValue) } else { collapsedSections.insert(section.rawValue) }
    }

    var parsedNotifyThresholds: [Int] { ThresholdTracker.parseThresholds(notifyThresholds) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "pollInterval": Int(BackoffPolicy.defaultPollInterval),
            "warningThreshold": 60,
            "criticalThreshold": 85,
            "labelFormat": LabelFormat.session.rawValue,
            "historyDays": 90,
            "labelShowPercent": true,
            "labelShowCountdown": true,
            "labelShowResetTime": false,
            "labelShowStatus": true,
            "hideCacheReadsByDefault": true,
            "terminal": TerminalCatalog.defaultID,
            "customTerminalCommand": "open -a Terminal {script}",
            "notifyUsage": true,
            "notifyThresholds": "75, 90",
            "notifyWaiting": false,
            "tokenChartStyle": TokenChartStyle.columns.rawValue,
        ])
        pollInterval = max(Int(BackoffPolicy.minimumPollInterval), defaults.integer(forKey: "pollInterval"))
        warningThreshold = defaults.integer(forKey: "warningThreshold")
        criticalThreshold = defaults.integer(forKey: "criticalThreshold")
        labelFormat = LabelFormat(rawValue: defaults.string(forKey: "labelFormat") ?? "") ?? .session
        historyDays = max(1, defaults.integer(forKey: "historyDays"))
        labelShowPercent = defaults.bool(forKey: "labelShowPercent")
        labelShowCountdown = defaults.bool(forKey: "labelShowCountdown")
        labelShowResetTime = defaults.bool(forKey: "labelShowResetTime")
        labelShowStatus = defaults.bool(forKey: "labelShowStatus")
        hideCacheReadsByDefault = defaults.bool(forKey: "hideCacheReadsByDefault")
        terminal = TerminalCatalog.migrate(defaults.string(forKey: "terminal"))
        customTerminalCommand = defaults.string(forKey: "customTerminalCommand") ?? ""
        notifyUsage = defaults.bool(forKey: "notifyUsage")
        notifyThresholds = defaults.string(forKey: "notifyThresholds") ?? "75, 90"
        notifyWaiting = defaults.bool(forKey: "notifyWaiting")
        hiddenSections = Set(defaults.stringArray(forKey: "hiddenSections") ?? [])
        collapsedSections = Set(defaults.stringArray(forKey: "collapsedSections") ?? [])
        tokenChartStyle = TokenChartStyle(rawValue: defaults.string(forKey: "tokenChartStyle") ?? "") ?? .columns
    }

    func level(for utilization: Double) -> UsageLevel {
        if utilization >= Double(criticalThreshold) { return .critical }
        if utilization >= Double(warningThreshold) { return .warning }
        return .normal
    }
}

enum UsageLevel {
    case normal, warning, critical
}
