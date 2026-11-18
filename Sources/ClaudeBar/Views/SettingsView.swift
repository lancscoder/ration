import AppKit
import ClaudeBarCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let state: AppState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?
    @State private var cacheError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            loginStatus = LaunchAtLogin.status
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                state.showingSettings = false
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .controlSize(.small)
            .help("Back to usage (Esc)")
            Spacer()
            Text("Settings").font(.headline)
            Spacer()
            // Balances the back button so the title stays centred.
            Label("Back", systemImage: "chevron.left").controlSize(.small).hidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var form: some View {
        @Bindable var prefs = state.prefs
        Form {
            Section("Menu bar") {
                LabeledContent("Preview") {
                    Image(nsImage: MenuBarLabelRenderer.image(for: state.menuBarModel))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }
                Picker("Limit", selection: $prefs.labelFormat) {
                    ForEach(LabelFormat.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Percent used", isOn: $prefs.labelShowPercent)
                Toggle("Time until reset", isOn: $prefs.labelShowCountdown)
                Toggle("Reset time", isOn: $prefs.labelShowResetTime)
                Toggle("Session status dot (green working, blue waiting)", isOn: $prefs.labelShowStatus)
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
                ForEach(PanelSection.allCases) { section in
                    Toggle(isOn: Binding(get: { prefs.isVisible(section) }, set: { prefs.setVisible(section, $0) })) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
                Picker("Token history", selection: $prefs.tokenChartStyle) {
                    ForEach(TokenChartStyle.allCases) { Text($0.title).tag($0) }
                }
                if !prefs.collapsedSections.isEmpty {
                    Button("Expand all sections") { prefs.collapsedSections = [] }
                }
            } header: {
                Text("Panel sections")
            } footer: {
                Text("Click a section's title in the panel to collapse or expand it; ClaudeBar remembers your choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Plan limits") {
                Stepper(value: $prefs.pollInterval, in: Int(BackoffPolicy.minimumPollInterval)...3600, step: 60) {
                    LabeledContent("Check usage every", value: Fmt.duration(TimeInterval(prefs.pollInterval)))
                }
                .onChange(of: prefs.pollInterval) { state.pollIntervalChanged() }
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
            }

            Section {
                LabeledContent("Cache folder") {
                    Text(displayPath(AppPaths.cacheDirectory))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(AppPaths.cacheDirectory.path)
                }
                HStack {
                    Button("Change…") { chooseCacheFolder() }
                    if isCacheOverridden {
                        Button("Use default") { setCacheFolder(nil) }
                    }
                    Spacer()
                    Button("Open in Finder") {
                        try? FileManager.default.createDirectory(at: AppPaths.cacheDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppPaths.cacheDirectory)
                    }
                }
                if let cacheError {
                    Text(cacheError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Holds the last usage response, quota history and the token index. Changing it moves those files and relaunches ClaudeBar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Logs", value: AppPaths.claudeRoots().map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", "))
                Text("Usage data comes from an undocumented endpoint and may change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func isInstalled(_ choice: TerminalChoice) -> Bool {
        guard let id = choice.bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    private var isCacheOverridden: Bool {
        AppPaths.cacheDirectory.standardizedFileURL != AppPaths.defaultCacheDirectory.standardizedFileURL
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where ClaudeBar keeps its cache files."
        panel.directoryURL = AppPaths.cacheDirectory.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCacheFolder(url)
    }

    /// Moves the cache files, stores the new folder (nil = default) and relaunches,
    /// since the caches are opened once at launch.
    private func setCacheFolder(_ url: URL?) {
        let old = AppPaths.cacheDirectory
        let new = (url ?? AppPaths.defaultCacheDirectory).standardizedFileURL
        guard new != old.standardizedFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: new.path) else {
                cacheError = "\(displayPath(new)) isn't writable."
                return
            }
            try AppPaths.moveCacheFiles(from: old, to: new)
        } catch {
            cacheError = "Couldn't move the cache: \(error.localizedDescription)"
            return
        }
        if let url {
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: AppPaths.cacheDirectoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppPaths.cacheDirectoryKey)
        }
        cacheError = nil
        Relauncher.relaunch()
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
