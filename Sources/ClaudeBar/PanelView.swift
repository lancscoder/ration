import ClaudeBarCore
import SwiftUI

struct PanelView: View {
    let state: AppState
    var snapshotMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude usage").font(.headline)
            if let r = state.usage.response {
                if let s = r.session { Text("Session: \(Fmt.percent(s.utilization))") }
                if let w = r.weekly { Text("Weekly: \(Fmt.percent(w.utilization))") }
            }
            if let msg = state.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { state.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 400)
    }
}
