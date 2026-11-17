import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    let state: AppState

    var body: some View {
        @Bindable var prefs = state.prefs
        Form {
            Section("Plan limits") {
                Stepper(value: $prefs.pollInterval, in: Int(BackoffPolicy.minimumPollInterval)...3600, step: 60) {
                    LabeledContent("Poll every", value: Fmt.duration(TimeInterval(prefs.pollInterval)))
                }
                .onChange(of: prefs.pollInterval) { state.pollIntervalChanged() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
