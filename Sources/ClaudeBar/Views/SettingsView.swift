import AppKit
import ClaudeBarCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let state: AppState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = state.prefs
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $prefs.labelFormat) {
                    ForEach(LabelFormat.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $prefs.warningThreshold, in: 1...99) {
                    LabeledContent("Amber from", value: "\(prefs.warningThreshold)%")
                }
                .onChange(of: prefs.warningThreshold) {
                    if prefs.criticalThreshold <= prefs.warningThreshold { prefs.criticalThreshold = min(100, prefs.warningThreshold + 1) }
                }
                Stepper(value: $prefs.criticalThreshold, in: 2...100) {
                    LabeledContent("Red from", value: "\(prefs.criticalThreshold)%")
                }
                .onChange(of: prefs.criticalThreshold) {
                    if prefs.warningThreshold >= prefs.criticalThreshold { prefs.warningThreshold = max(1, prefs.criticalThreshold - 1) }
                }
            }

            Section {
                Stepper(value: $prefs.pollInterval, in: Int(BackoffPolicy.minimumPollInterval)...3600, step: 60) {
                    LabeledContent("Check usage every", value: Fmt.duration(TimeInterval(prefs.pollInterval)))
                }
                .onChange(of: prefs.pollInterval) { state.pollIntervalChanged() }
            } header: {
                Text("Plan limits")
            } footer: {
                Text("The usage endpoint is heavily rate-limited; ClaudeBar never polls more often than every 3 minutes and backs off on HTTP 429.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify when usage crosses thresholds", isOn: $prefs.notifyUsage)
                    .onChange(of: prefs.notifyUsage) { if prefs.notifyUsage { state.notifier.requestAuthorization() } }
                TextField("Thresholds (%)", text: $prefs.notifyThresholds, prompt: Text("75, 90"))
                    .disabled(!prefs.notifyUsage)
                    .help("Comma-separated percentages. Each fires once per 5-hour or weekly window.")
                Toggle("Notify when a session is waiting for input", isOn: $prefs.notifyWaiting)
                    .onChange(of: prefs.notifyWaiting) { if prefs.notifyWaiting { state.notifier.requestAuthorization() } }
                Button("Send test notification") {
                    state.notifier.requestAuthorization()
                    state.notifier.send(title: "ClaudeBar", body: "Notifications are working.", id: "test-\(UUID().uuidString)")
                }
            }

            Section {
                Picker("Resume in", selection: $prefs.terminal) {
                    ForEach(TerminalChoice.allCases) { choice in
                        Text(choice.title + (isInstalled(choice) ? "" : " (not installed)")).tag(choice)
                    }
                }
                if prefs.terminal == .custom {
                    TextField("Command", text: $prefs.customTerminalCommand, prompt: Text("open -a Terminal {script}"))
                        .font(.body.monospaced())
                }
            } header: {
                Text("Sessions")
            } footer: {
                if prefs.terminal == .custom {
                    Text("Placeholders (shell-quoted): {script} a .command file that cds and runs claude, {cwd}, {sessionId}, {command}. Runs via zsh -lc.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Tokens") {
                Stepper(value: $prefs.historyDays, in: 7...365, step: 7) {
                    LabeledContent("Days of history (\"All\")", value: "\(prefs.historyDays)")
                }
                .onChange(of: prefs.historyDays) { state.historyDaysChanged() }
                Toggle("Hide cache-read tokens by default", isOn: $prefs.hideCacheReadsByDefault)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { applyLaunchAtLogin() }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve ClaudeBar in Login Items.").font(.caption)
                        Spacer()
                        Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("General")
            } footer: {
                Text("Install with `make install` first so the login item points at ~/Applications/ClaudeBar.app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Logs", value: AppPaths.claudeRoots().map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", "))
                HStack {
                    Button("Open cache folder") {
                        try? FileManager.default.createDirectory(at: AppPaths.cacheDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppPaths.cacheDirectory)
                    }
                    Spacer()
                    Text("Usage data comes from an undocumented endpoint and may change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            loginStatus = LaunchAtLogin.status
        }
    }

    private func isInstalled(_ choice: TerminalChoice) -> Bool {
        guard let id = choice.bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    private func applyLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(launchAtLogin)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = LaunchAtLogin.status
        let enabled = LaunchAtLogin.isEnabled || loginStatus == .requiresApproval
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }
}
