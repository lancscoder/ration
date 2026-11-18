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
    @State private var claudeFolderError: String?
    @State private var terminals: [TerminalApp] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
        }
        .onAppear {
            terminals = TerminalDiscovery.installed()
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
            .controlSize(.regular)
            .help("Back to usage (Esc)")
            Spacer()
            Text("Settings").font(.headline)
            Spacer()
            // Balances the back button so the title stays centred.
            Label("Back", systemImage: "chevron.left").hidden()
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
                ShortcutRecorder(state: state)
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
                Toggle("Notify when a nearly used-up limit resets (90%+)", isOn: $prefs.notifyReset)
                    .onChange(of: prefs.notifyReset) {
                        if prefs.notifyReset { state.notifier.requestAuthorization() } else { state.notifier.cancelResetReminders() }
                    }
                Toggle("Notify when a session is waiting for input", isOn: $prefs.notifyWaiting)
                    .onChange(of: prefs.notifyWaiting) { if prefs.notifyWaiting { state.notifier.requestAuthorization() } }
                Button("Send test notification") {
                    state.notifier.requestAuthorization()
                    state.notifier.send(title: "ClaudeBar", body: "Notifications are working.", id: "test-\(UUID().uuidString)")
                }
            }

            Section {
                Picker("Resume in", selection: $prefs.terminal) {
                    ForEach(terminals) { app in
                        Text(app.name).tag(app.id)
                    }
                    if prefs.terminal != TerminalCatalog.customID, !terminals.contains(where: { $0.id == prefs.terminal }) {
                        Text("\(TerminalDiscovery.displayName(id: prefs.terminal)) (not installed)").tag(prefs.terminal)
                    }
                    Divider()
                    Text("Custom command").tag(TerminalCatalog.customID)
                }
                Picker("List ended sessions from", selection: $prefs.endedSessionDays) {
                    ForEach(Preferences.endedSessionDayChoices, id: \.self) { days in
                        Text(days == 1 ? "Last 24 hours" : "Last \(days) days").tag(days)
                    }
                }
                if prefs.terminal == TerminalCatalog.customID {
                    TextField("Command", text: $prefs.customTerminalCommand, prompt: Text("open -a Terminal {script}"))
                        .font(.body.monospaced())
                }
            } header: {
                Text("Sessions")
            } footer: {
                Group {
                    if prefs.terminal == TerminalCatalog.customID {
                        Text("Placeholders (shell-quoted): {script} a .command file that cds and runs claude, {cwd}, {sessionId}, {command}. Runs via zsh -lc.")
                    } else if let app = terminals.first(where: { $0.id == prefs.terminal }), app.needsPaste {
                        Text("\(app.name) can't be told to run a command, so Resume opens it and copies the command for you to paste.")
                    } else {
                        Text("Resume appears on ended sessions in the panel. Terminals are detected automatically.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Claude folder") {
                    Text(claudeRootsText)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(AppPaths.claudeRoots().map(\.path).joined(separator: "\n"))
                }
                HStack {
                    Button("Change…") { chooseClaudeFolder() }
                    if AppPaths.claudeFolderOverride() != nil {
                        Button("Detect automatically") { setClaudeFolder(nil) }
                    }
                    Spacer()
                }
                if let claudeFolderError {
                    Text(claudeFolderError).font(.caption).foregroundStyle(.red)
                }
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
                Text("Folders")
            } footer: {
                Text("Claude folder: where Claude Code keeps its logs and sessions (normally ~/.claude, or CLAUDE_CONFIG_DIR). Cache folder: ClaudeBar's own files; changing it moves them. Either change relaunches ClaudeBar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("Usage data comes from an undocumented endpoint and may change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var isCacheOverridden: Bool {
        AppPaths.cacheDirectory.standardizedFileURL != AppPaths.defaultCacheDirectory.standardizedFileURL
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var claudeRootsText: String {
        let roots = AppPaths.claudeRoots()
        guard !roots.isEmpty else { return "Not found" }
        let text = roots.map(displayPath).joined(separator: ", ")
        return AppPaths.claudeFolderOverride() == nil ? text + " (auto)" : text
    }

    private func chooseClaudeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use Folder"
        panel.message = "Choose your Claude Code folder (the one containing projects/ and sessions/)."
        panel.directoryURL = AppPaths.claudeRoots().first ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setClaudeFolder(url)
    }

    /// Stores the Claude folder (nil = auto-detect) and relaunches, since the
    /// log index, session monitor and credentials are set up at launch.
    private func setClaudeFolder(_ url: URL?) {
        if let url {
            guard AppPaths.looksLikeClaudeFolder(url) else {
                claudeFolderError = "\(displayPath(url)) has no projects or sessions folder, so it doesn't look like a Claude Code folder."
                return
            }
            guard url.standardizedFileURL != AppPaths.claudeFolderOverride() else { return }
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: AppPaths.claudeFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppPaths.claudeFolderKey)
        }
        claudeFolderError = nil
        Relauncher.relaunch()
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

/// Records a global shortcut: click, press the keys (⌘, ⌃ or ⌥ required), Esc cancels.
struct ShortcutRecorder: View {
    let state: AppState
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        LabeledContent("Open panel shortcut") {
            HStack(spacing: 6) {
                Button {
                    state.isRecordingShortcut ? stop() : start()
                } label: {
                    Text(state.isRecordingShortcut ? "Press keys…" : (state.prefs.hotKey?.display ?? "Record Shortcut"))
                        .monospaced(state.prefs.hotKey != nil && !state.isRecordingShortcut)
                        .frame(minWidth: 90)
                }
                .help(state.isRecordingShortcut ? "Press the new shortcut, or Esc to cancel" : "Click to record a shortcut")
                if state.prefs.hotKey != nil, !state.isRecordingShortcut {
                    Button {
                        state.prefs.hotKey = nil
                        state.applyHotKey()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove shortcut")
                }
            }
        }
        .onDisappear { if state.isRecordingShortcut { stop() } }
        if let message = hint ?? state.hotKeyError {
            Text(message).font(.caption).foregroundStyle(hint == nil ? .red : .secondary)
        }
    }

    private func start() {
        hint = "Include ⌘, ⌃ or ⌥. Esc cancels."
        state.isRecordingShortcut = true
        state.applyHotKey() // releases the current one so it can be pressed again
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            let shortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.rawValue,
                                          key: HotKeyShortcut.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
            guard shortcut.isValid else {
                hint = "\(shortcut.display.isEmpty ? "That key" : shortcut.display) needs ⌘, ⌃ or ⌥."
                return nil
            }
            state.prefs.hotKey = shortcut
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hint = nil
        state.isRecordingShortcut = false
        state.applyHotKey()
    }
}
