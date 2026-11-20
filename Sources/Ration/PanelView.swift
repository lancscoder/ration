import AppKit
import RationCore
import SwiftUI

struct PanelView: View {
    let state: AppState
    var snapshotMode = false
    @State private var contentHeight: CGFloat = 400

    private let width: CGFloat = 400
    private let maxHeight: CGFloat = 760
    /// Settings is a scrolling form with no natural height, so it gets a fixed one.
    private let settingsHeight: CGFloat = 620

    var body: some View {
        if snapshotMode {
            if state.showingSettings {
                SettingsView(state: state).frame(width: width, height: settingsHeight)
            } else {
                content.frame(width: width)
            }
        } else {
            let height = state.showingSettings ? settingsHeight : min(contentHeight, maxHeight)
            Group {
                if state.showingSettings {
                    SettingsView(state: state)
                } else {
                    ScrollView(.vertical) {
                        content
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                            })
                    }
                    .scrollIndicators(.automatic)
                    .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
                }
            }
            .frame(width: width, height: height)
            .background(PanelWindowBridge(state: state, contentHeight: height))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if prefs.isVisible(.limits) { LimitsSection(state: state) }
            if prefs.isVisible(.burnRate) { BurnRateSection(state: state) }
            if prefs.isVisible(.tokens) { TokensSection(state: state) }
            if prefs.isVisible(.sessions) { SessionsSection(state: state) }
            FooterView(state: state)
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(Color.accentColor)
            Text("Ration").font(.headline)
            Spacer()
            Button {
                ClaudeLauncher.open()
            } label: {
                Label(ClaudeLauncher.title, systemImage: "arrow.up.forward.app")
            }
            .controlSize(.regular)
            .help(ClaudeLauncher.desktopAppURL == nil ? "Open claude.ai in your browser" : "Open the Claude desktop app")
        }
    }

    private var prefs: Preferences { state.prefs }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Bridges to the panel's NSWindow:
/// - Keyboard: `r` refreshes, `c` toggles cache reads, `Esc` closes the panel
///   (or leaves Settings when that is showing).
///   A local monitor sees only this app's events; it ignores other windows and
///   anything typed into a text field.
/// - Size: MenuBarExtra windows grow with their content but never shrink, so
///   when the content gets shorter (e.g. a section collapses) the window is
///   resized explicitly, keeping its top edge under the menu bar.
private struct PanelWindowBridge: NSViewRepresentable {
    let state: AppState
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, state: state)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let height = contentHeight
        // Defer until SwiftUI has finished this layout pass.
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            Self.fit(window, toContentHeight: height)
        }
    }

    static func fit(_ window: NSWindow, toContentHeight height: CGFloat) {
        guard height > 0 else { return }
        let current = window.contentRect(forFrameRect: window.frame)
        guard abs(current.height - height) > 0.5 else { return }
        let target = window.frameRect(forContentRect: NSRect(x: current.minX, y: current.minY, width: current.width, height: height))
        var frame = window.frame
        frame.origin.y = frame.maxY - target.height // keep the top edge fixed
        frame.size.height = target.height
        window.setFrame(frame, display: true, animate: false)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(view: NSView, state: AppState) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                guard let window = view?.window, event.window === window, !state.isRecordingShortcut else { return event }
                if window.firstResponder is NSTextView { return event }
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return event }
                switch event.keyCode {
                case 53: // Esc
                    if state.showingSettings {
                        state.showingSettings = false
                    } else {
                        window.close()
                    }
                    return nil
                default: break
                }
                if state.showingSettings { return event }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "r":
                    state.refresh()
                    return nil
                case "c":
                    state.toggleCacheReads()
                    return nil
                default:
                    return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
