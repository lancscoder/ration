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

enum TerminalChoice: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .custom: return "Custom command"
        }
    }
    var bundleID: String? {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .custom: return nil
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
    var terminal: TerminalChoice { didSet { defaults.set(terminal.rawValue, forKey: "terminal") } }
    var customTerminalCommand: String { didSet { defaults.set(customTerminalCommand, forKey: "customTerminalCommand") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "pollInterval": Int(BackoffPolicy.defaultPollInterval),
            "warningThreshold": 60,
            "criticalThreshold": 85,
            "labelFormat": LabelFormat.session.rawValue,
            "historyDays": 90,
            "hideCacheReadsByDefault": true,
            "terminal": TerminalChoice.terminal.rawValue,
            "customTerminalCommand": "open -a Terminal {script}",
        ])
        pollInterval = max(Int(BackoffPolicy.minimumPollInterval), defaults.integer(forKey: "pollInterval"))
        warningThreshold = defaults.integer(forKey: "warningThreshold")
        criticalThreshold = defaults.integer(forKey: "criticalThreshold")
        labelFormat = LabelFormat(rawValue: defaults.string(forKey: "labelFormat") ?? "") ?? .session
        historyDays = max(1, defaults.integer(forKey: "historyDays"))
        hideCacheReadsByDefault = defaults.bool(forKey: "hideCacheReadsByDefault")
        terminal = TerminalChoice(rawValue: defaults.string(forKey: "terminal") ?? "") ?? .terminal
        customTerminalCommand = defaults.string(forKey: "customTerminalCommand") ?? ""
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
