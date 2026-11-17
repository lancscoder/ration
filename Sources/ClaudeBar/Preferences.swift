import ClaudeBarCore
import Foundation
import Observation

enum LabelFormat: String, CaseIterable, Identifiable {
    case session, weekly, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: return "5-hour % and reset"
        case .weekly: return "Weekly % and reset"
        case .both: return "5-hour % and weekly %"
        }
    }
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
    var historyDays: Int { didSet { defaults.set(historyDays, forKey: "historyDays") } }
    var hideCacheReadsByDefault: Bool { didSet { defaults.set(hideCacheReadsByDefault, forKey: "hideCacheReadsByDefault") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "pollInterval": Int(BackoffPolicy.defaultPollInterval),
            "warningThreshold": 60,
            "criticalThreshold": 85,
            "labelFormat": LabelFormat.session.rawValue,
            "historyDays": 90,
            "hideCacheReadsByDefault": true,
        ])
        pollInterval = max(Int(BackoffPolicy.minimumPollInterval), defaults.integer(forKey: "pollInterval"))
        warningThreshold = defaults.integer(forKey: "warningThreshold")
        criticalThreshold = defaults.integer(forKey: "criticalThreshold")
        labelFormat = LabelFormat(rawValue: defaults.string(forKey: "labelFormat") ?? "") ?? .session
        historyDays = max(1, defaults.integer(forKey: "historyDays"))
        hideCacheReadsByDefault = defaults.bool(forKey: "hideCacheReadsByDefault")
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
