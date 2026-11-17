import AppKit
import ClaudeBarCore
import SwiftUI

/// Debug aid: `ClaudeBar --stress <seconds>` opens and closes the real menu bar
/// panel repeatedly and floods it with synthetic mouse events (routed through
/// NSWindow.sendEvent, so tracking areas fire) while the app keeps updating,
/// to reproduce hover/hit-testing crashes.
@MainActor
enum Stress {
    static var timer: Timer?

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--stress") else { return }
        let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 60
        let mode = ProcessInfo.processInfo.environment["STRESS_MODE"] ?? "all"
        print("stress mode: \(mode)")
        let start = Date()
        var n = 0
        var toggles = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.003, repeats: true) { _ in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(start) > seconds {
                    print("stress: survived \(n) events, \(toggles) open/close cycles in \(Int(seconds))s")
                    exit(0)
                }
                n += 1
                if mode == "idle" { return }
                // Open/close the panel every ~0.6 s.
                if n % 200 == 1 {
                    statusButton()?.performClick(nil)
                    toggles += 1
                    return
                }
                if mode == "toggle" { return }
                guard let panel = panelWindow(), panel.isVisible, let content = panel.contentView else { return }
                let size = content.bounds.size
                let p = NSPoint(x: .random(in: -5...size.width + 5), y: .random(in: -5...size.height + 5))
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                               context: nil, eventNumber: n, clickCount: 0, pressure: 0)
                if let event { panel.sendEvent(event) }
                if n % 3 == 0, let hostingView = deepestHostingView(in: content) {
                    let e = NSEvent.enterExitEvent(with: n % 2 == 0 ? .mouseEntered : .mouseExited, location: p, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                                   context: nil, eventNumber: n, trackingNumber: 0, userData: nil)
                    if let e { n % 2 == 0 ? hostingView.mouseEntered(with: e) : hostingView.mouseExited(with: e) }
                }
            }
        }
    }

    static func statusButton() -> NSStatusBarButton? {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let b = find(NSStatusBarButton.self, in: w.contentView) { return b }
        }
        return nil
    }

    static func panelWindow() -> NSWindow? {
        NSApp.windows.first { w in
            !String(describing: type(of: w)).contains("StatusBar") && w.title != "ClaudeBar Settings" && w.contentView != nil && w.frame.width > 300
        }
    }

    static func deepestHostingView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("Hosting") { return view }
        for sub in view.subviews { if let h = deepestHostingView(in: sub) { return h } }
        return nil
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }
}
