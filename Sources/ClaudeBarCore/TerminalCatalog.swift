import Foundation

/// How a terminal app is asked to open a resumed session.
public enum TerminalLaunchMethod: Sendable, Equatable {
    /// Hand it the generated `.command` script (apps registered as a Shell for shell scripts).
    case openScript
    /// `open -na <app> --args …` with `{cwd}` and `{script}` substituted (no shell involved).
    case openArgs([String])
    /// The app can't be told to run a command: open it (in the project folder when it
    /// accepts folders) and put the resume command on the clipboard to paste.
    case pasteCommand(opensFolder: Bool)
}

/// A terminal ClaudeBar knows how to drive, or one discovered on this Mac.
public struct TerminalApp: Sendable, Identifiable, Equatable {
    /// Bundle identifier.
    public var id: String
    public var name: String
    public var method: TerminalLaunchMethod
    public var appURL: URL?

    public init(id: String, name: String, method: TerminalLaunchMethod, appURL: URL? = nil) {
        self.id = id
        self.name = name
        self.method = method
        self.appURL = appURL
    }

    public var needsPaste: Bool {
        if case .pasteCommand = method { return true }
        return false
    }
}

public enum TerminalCatalog {
    public static let customID = "custom"
    public static let defaultID = "com.apple.Terminal"

    public struct Known: Sendable {
        public var bundleID: String
        public var name: String
        public var method: TerminalLaunchMethod
        /// App bundle names to look for when the bundle ID isn't known for sure.
        public var appNames: [String]
    }

    /// In display order. Methods are only what each app documents or registers for;
    /// anything else falls back to pasting the command.
    public static let known: [Known] = [
        Known(bundleID: "com.apple.Terminal", name: "Terminal", method: .openScript, appNames: []),
        Known(bundleID: "com.googlecode.iterm2", name: "iTerm2", method: .openScript, appNames: []),
        Known(bundleID: "com.mitchellh.ghostty", name: "Ghostty",
              method: .openArgs(["--working-directory={cwd}", "-e", "{script}"]), appNames: []),
        Known(bundleID: "com.cmuxterm.app", name: "cmux", method: .openScript, appNames: []),
        Known(bundleID: "dev.warp.Warp-Stable", name: "Warp", method: .openScript, appNames: []),
        Known(bundleID: "com.github.wez.wezterm", name: "WezTerm",
              method: .openArgs(["start", "--cwd", "{cwd}", "--", "{script}"]), appNames: []),
        Known(bundleID: "net.kovidgoyal.kitty", name: "kitty",
              method: .openArgs(["--directory", "{cwd}", "{script}"]), appNames: []),
        Known(bundleID: "org.alacritty", name: "Alacritty",
              method: .openArgs(["--working-directory", "{cwd}", "-e", "{script}"]), appNames: []),
        Known(bundleID: "orca", name: "Orca", method: .pasteCommand(opensFolder: false), appNames: ["Orca.app"]),
        Known(bundleID: "co.zeit.hyper", name: "Hyper", method: .pasteCommand(opensFolder: false), appNames: []),
        Known(bundleID: "org.tabby", name: "Tabby", method: .pasteCommand(opensFolder: false), appNames: []),
    ]

    /// Terminals that were offered once but didn't work; a saved choice falls back to the default.
    static let withdrawn: Set<String> = ["com.superlogical.rex", "dev.herdr.app"]

    /// Maps the pre-catalog setting values (`terminal`, `iterm`, `ghostty`) to bundle IDs,
    /// and withdrawn terminals to the default.
    public static func migrate(_ stored: String?) -> String {
        if let stored, withdrawn.contains(stored) { return defaultID }
        switch stored {
        case nil, "", "terminal": return defaultID
        case "iterm": return "com.googlecode.iterm2"
        case "ghostty": return "com.mitchellh.ghostty"
        case let value?: return value
        }
    }

    public static func known(bundleID: String) -> Known? {
        known.first { $0.bundleID == bundleID }
    }

    static let shellScriptTypes: Set<String> = ["com.apple.terminal.shell-script", "public.unix-executable"]

    /// Whether an app's `CFBundleDocumentTypes` declare it a *Shell* for shell scripts,
    /// i.e. it runs them rather than just editing or viewing them.
    public static func isShellHandler(documentTypes: [[String: Any]]) -> Bool {
        documentTypes.contains { type in
            guard (type["CFBundleTypeRole"] as? String) == "Shell" else { return false }
            let types = (type["LSItemContentTypes"] as? [String]) ?? []
            let extensions = (type["CFBundleTypeExtensions"] as? [String]) ?? []
            return !shellScriptTypes.isDisjoint(with: types) || extensions.contains("command")
        }
    }

    /// Substitutes `{cwd}` and `{script}` in `openArgs` arguments.
    public static func expand(args: [String], cwd: String, script: String) -> [String] {
        args.map { $0.replacingOccurrences(of: "{cwd}", with: cwd).replacingOccurrences(of: "{script}", with: script) }
    }

    /// The command to paste into a terminal that can't be told to run one.
    public static func pasteCommand(cwd: String, sessionId: String) -> String? {
        guard ResumeCommand.isSafeSessionId(sessionId) else { return nil }
        return "cd \(ResumeCommand.shellQuote(cwd)) && \(ResumeCommand.claudeCommand(sessionId: sessionId))"
    }
}
