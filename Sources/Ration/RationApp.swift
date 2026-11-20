import AppKit
import RationCore
import SwiftUI

@main
struct RationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state)
        } label: {
            MenuBarLabelView(state: state)
                .task { state.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: Info.plist sets LSUIElement, but `swift run` has no bundle.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            Snapshot.runIfRequested()
            Stress.runIfRequested()
        }
    }
}

/// One-time carry-over from the app's previous name (ClaudeBar): settings and cache.
enum LegacyMigration {
    static let oldBundleID = "local.claudebar.ClaudeBar"
    private static let doneKey = "migratedFromClaudeBar"

    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        if let old = defaults.persistentDomain(forName: oldBundleID) {
            for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") {
                defaults.set(value, forKey: key)
            }
        }
        // Default cache folder moved with the bundle ID; a custom one is kept as is.
        if defaults.string(forKey: AppPaths.cacheDirectoryKey) == nil {
            let oldCache = AppPaths.defaultCacheDirectory.deletingLastPathComponent().appendingPathComponent(oldBundleID)
            if FileManager.default.fileExists(atPath: oldCache.path) {
                try? AppPaths.moveCacheFiles(from: oldCache, to: AppPaths.defaultCacheDirectory)
            }
        }
    }
}
