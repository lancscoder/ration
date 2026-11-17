import AppKit
import ClaudeBarCore
import SwiftUI

@main
struct ClaudeBarApp: App {
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
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }
}
