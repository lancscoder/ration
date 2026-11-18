import ClaudeBarCore
import Foundation

/// Installs ClaudeBar's hooks into Claude Code's user settings (opt-in, from Settings).
@MainActor
enum HooksSetup {
    /// The helper inside this app bundle; nil when not running from a built .app.
    static var helperPath: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claudebar-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static var settingsURL: URL {
        let root = AppPaths.claudeRoots().first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("settings.json")
    }

    static var stateDir: String { AppPaths.hookStateDirectory.path }

    /// Whether this copy of the app lives somewhere stable (hooks store its path).
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    static func status() throws -> HookInstaller.Status {
        let settings = try ClaudeSettingsFile.load(settingsURL)
        guard let helper = helperPath else {
            return HookInstaller.ourCommandsPresent(settings) ? .outdated : .notInstalled
        }
        return HookInstaller.status(of: settings, helper: helper, stateDir: stateDir)
    }

    static func install() throws {
        guard let helper = helperPath else { throw SetupError.noHelper }
        let settings = try ClaudeSettingsFile.load(settingsURL)
        try ClaudeSettingsFile.save(HookInstaller.install(into: settings, helper: helper, stateDir: stateDir), to: settingsURL)
    }

    static func uninstall() throws {
        let settings = try ClaudeSettingsFile.load(settingsURL)
        try ClaudeSettingsFile.save(HookInstaller.uninstall(from: settings), to: settingsURL)
    }

    enum SetupError: LocalizedError {
        case noHelper
        var errorDescription: String? {
            "The hook helper isn't in this copy of ClaudeBar. Build it with `make app` or `make install`."
        }
    }
}
