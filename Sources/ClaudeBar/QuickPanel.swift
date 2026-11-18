import AppKit
import Carbon.HIToolbox
import ClaudeBarCore
import os
import SwiftUI

/// A system-wide shortcut via Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission (unlike a global NSEvent monitor).
@MainActor
final class GlobalHotKey {
    nonisolated private static let log = Logger(subsystem: Log.subsystem, category: "hotkey")
    nonisolated(unsafe) private static var onPress: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// - Returns: false when the shortcut couldn't be registered (e.g. another app owns it).
    @discardableResult
    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.onPress = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.onPress?() } }
                return noErr
            }, 1, &spec, nil, &handlerRef)
            if status != noErr { Self.log.error("InstallEventHandler failed: \(status)") }
        }
        let id = EventHotKeyID(signature: OSType(0x4342_4152), id: 1) // "CBAR"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Self.log.error("RegisterEventHotKey failed: \(status)")
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

/// The panel opened by the global shortcut.
///
/// A `MenuBarExtra` can't be opened from code (its status button has no action
/// and ignores synthetic clicks and accessibility presses), so the shortcut shows
/// the same `PanelView` in a borderless panel placed under the menu bar icon.
/// It closes on Esc, on the shortcut again, or when it loses focus.
@MainActor
final class QuickPanel: NSObject, NSWindowDelegate {
    private let state: AppState
    private var panel: NSPanel?
    private let width: CGFloat = 400

    init(state: AppState) {
        self.state = state
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.showingSettings = false
        panel.setFrame(frame(height: panel.frame.height), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelView(state: state))
        host.sizingOptions = [] // the panel's own bridge sizes the window
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = effect.bounds
        effect.addSubview(host)
        panel.contentView = effect
        return panel
    }

    /// Under the menu bar icon, clamped to the screen; top-right corner if the icon isn't found.
    private func frame(height: CGFloat) -> NSRect {
        let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible }
        let screen = statusWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = (statusWindow?.frame.minY ?? visible.maxY) - 4
        var x = (statusWindow.map { $0.frame.midX } ?? visible.maxX) - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes it, like the menu bar panel. A sheet or open
        // panel started from Settings also takes focus; that's fine, as both
        // continue without the quick panel.
        close()
    }
}

/// Borderless panels can't become key by default; this one must, for typing and Esc.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
