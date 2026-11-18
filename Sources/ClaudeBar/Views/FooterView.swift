import AppKit
import ClaudeBarCore
import SwiftUI

struct FooterView: View {
    let state: AppState
    /// Name of the button under the pointer. Shown in place of the "Updated" text,
    /// because standard tooltips are unreliable inside menu bar panels.
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = state.statusMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let hovered {
                    Text(hovered)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                } else {
                    updatedText
                }
                Spacer()
                IconButton(systemImage: "arrow.clockwise", help: "Refresh now (r)", hovered: $hovered) { state.refresh() }
                IconButton(systemImage: "chart.line.uptrend.xyaxis", help: "Usage page on claude.ai", hovered: $hovered) {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                IconButton(systemImage: "gearshape", help: "Settings", hovered: $hovered) {
                    state.showingSettings = true
                }
                IconButton(systemImage: "power", help: "Quit ClaudeBar", hovered: $hovered) { NSApp.terminate(nil) }
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }

    @ViewBuilder private var updatedText: some View {
        if let fetched = state.usage.fetchedAt {
            HStack(spacing: 4) {
                if state.isUsageStale {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                Text("Updated \(Fmt.ago(fetched, now: state.now))")
                    .foregroundStyle(state.isUsageStale ? Color.orange : Color.secondary)
            }
            .font(.caption)
        } else {
            Text("Not updated yet").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    var hovered: Binding<String?>?
    let action: () -> Void
    @State private var isHovering = false

    init(systemImage: String, help: String, hovered: Binding<String?>? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.hovered = hovered
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            isHovering = inside
            if inside {
                hovered?.wrappedValue = help
            } else if hovered?.wrappedValue == help {
                hovered?.wrappedValue = nil
            }
        }
    }
}

/// Opens the Claude desktop app if installed, otherwise claude.ai.
enum ClaudeLauncher {
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    static var desktopAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleID)
    }

    static var title: String { desktopAppURL == nil ? "Open claude.ai" : "Open Claude" }

    static func open() {
        if let app = desktopAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if error != nil { DispatchQueue.main.async { openWeb() } }
            }
        } else {
            openWeb()
        }
    }

    static func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/new")!)
    }
}
