import AppKit
import ClaudeBarCore
import SwiftUI

struct PanelView: View {
    let state: AppState
    var snapshotMode = false
    @State private var contentHeight: CGFloat = 400

    private let width: CGFloat = 400
    private let maxHeight: CGFloat = 760

    var body: some View {
        if snapshotMode {
            content.frame(width: width)
        } else {
            ScrollView(.vertical) {
                content
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                    })
            }
            .scrollIndicators(.automatic)
            .frame(width: width, height: min(contentHeight, maxHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            .background(KeyboardShortcuts(state: state))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            LimitsSection(state: state)
            BurnRateSection(state: state)
            TokensSection(state: state)
            FooterView(state: state)
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(Color.accentColor)
            Text("ClaudeBar").font(.headline)
            Spacer()
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// `r` refreshes, `c` toggles cache reads, `Esc` closes the panel.
/// A local monitor sees only this app's events; it ignores the Settings
/// window and anything typed into a text field.
private struct KeyboardShortcuts: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, state: state)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(view: NSView, state: AppState) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                guard let window = view?.window, event.window === window else { return event }
                if window.firstResponder is NSTextView { return event }
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return event }
                switch event.keyCode {
                case 53: // Esc
                    window.close()
                    return nil
                default: break
                }
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
