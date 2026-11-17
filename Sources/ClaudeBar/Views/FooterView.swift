import AppKit
import ClaudeBarCore
import SwiftUI

struct FooterView: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = state.statusMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                updatedText
                Spacer()
                IconButton(systemImage: "arrow.clockwise", help: "Refresh (r)") { state.refresh() }
                IconButton(systemImage: "safari", help: "Open claude.ai usage page") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                IconButton(systemImage: "gearshape", help: "Settings") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                IconButton(systemImage: "power", help: "Quit ClaudeBar") { NSApp.terminate(nil) }
            }
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
            .help(state.isUsageStale ? "Quota data is stale" : "Last successful quota fetch")
        } else {
            Text("Not updated yet").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
