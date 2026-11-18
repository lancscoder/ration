import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Hooks mode")
struct HooksTests {
    let helper = "/Users/me/Applications/ClaudeBar.app/Contents/Helpers/claudebar-hook"
    let stateDir = "/Users/me/Library/Application Support/local.claudebar.ClaudeBar/hook-state"

    /// Shaped like a real settings.json with other tools' hooks already present.
    func existingSettings() -> [String: Any] {
        [
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "SessionStart": [
                    ["matcher": "^(startup|resume)$", "hooks": [["type": "command", "command": "bash '/Users/me/.claude/hooks/herdr-agent-state.sh' session", "timeout": 10]]],
                    ["hooks": [["type": "command", "command": "/bin/sh -c 'rex __internal session-start || true'", "timeout": 5]]],
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"]]],
                ],
            ],
        ]
    }

    func json(_ object: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    @Test func installAddsOurEntriesAndKeepsEverythingElse() throws {
        let installed = HookInstaller.install(into: existingSettings(), helper: helper, stateDir: stateDir)
        #expect(installed["model"] as? String == "opus")
        let hooks = try #require(installed["hooks"] as? [String: Any])
        // Others' hooks are untouched.
        let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
        #expect(json(sessionStart) == json((existingSettings()["hooks"] as! [String: Any])["SessionStart"]!))
        // Our Stop entry is added beside the existing one.
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(json(stop).contains("afplay"))
        // Notification gets one group per matcher.
        let notification = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(Set(notification.compactMap { $0["matcher"] as? String }) == ["permission_prompt", "idle_prompt"])
        #expect(HookInstaller.status(of: installed, helper: helper, stateDir: stateDir) == .installed)
    }

    @Test func installIsIdempotentAndUninstallRestores() {
        let once = HookInstaller.install(into: existingSettings(), helper: helper, stateDir: stateDir)
        let twice = HookInstaller.install(into: once, helper: helper, stateDir: stateDir)
        #expect(json(once) == json(twice))
        #expect(json(HookInstaller.uninstall(from: twice)) == json(existingSettings()))
        // Uninstalling from a file with only our hooks removes the "hooks" key entirely.
        let onlyOurs = HookInstaller.install(into: ["model": "opus"], helper: helper, stateDir: stateDir)
        #expect(json(HookInstaller.uninstall(from: onlyOurs)) == json(["model": "opus"]))
    }

    @Test func detectsHooksFromAnotherCopy() {
        #expect(HookInstaller.status(of: existingSettings(), helper: helper, stateDir: stateDir) == .notInstalled)
        let elsewhere = HookInstaller.install(into: existingSettings(), helper: "/tmp/old/ClaudeBar.app/Contents/Helpers/claudebar-hook", stateDir: stateDir)
        #expect(HookInstaller.status(of: elsewhere, helper: helper, stateDir: stateDir) == .outdated)
    }

    @Test func commandQuotesPathsAndNeverFails() {
        let cmd = HookInstaller.command(helper: helper, state: .permission, stateDir: stateDir)
        #expect(cmd == "[ -x '\(helper)' ] && '\(helper)' permission '\(stateDir)' || true")
    }

    @Test func storeRecordsLoadsAndForgetsEndedSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudebar-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "11111111-aaaa-bbbb-cccc-000000000001"
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        try HookStateStore.record(.permission, sessionId: sid, event: "Notification", in: dir, now: t)
        try HookStateStore.record(.busy, sessionId: "../../etc/passwd", event: nil, in: dir, now: t) // rejected
        #expect(HookStateStore.load(from: dir) == [sid: HookStateRecord(state: .permission, at: t.timeIntervalSince1970, event: "Notification")])

        HookStateStore.prune(dir, olderThan: 3600, now: t.addingTimeInterval(60))
        #expect(HookStateStore.load(from: dir).count == 1)
        try HookStateStore.record(.ended, sessionId: sid, event: "SessionEnd", in: dir, now: t)
        #expect(HookStateStore.load(from: dir).isEmpty)
    }

    @Test func mergePrefersTheNewerReport() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        let busyHook = HookStateRecord(state: .busy, at: t.timeIntervalSince1970)
        // Hook newer than the file → hook wins.
        #expect(HookStateStore.merge(hook: busyHook, fileStatus: "idle", fileUpdated: t.addingTimeInterval(-10)) == ("busy", false))
        // File newer → file wins.
        #expect(HookStateStore.merge(hook: busyHook, fileStatus: "idle", fileUpdated: t.addingTimeInterval(10)) == ("idle", false))
        // No hook → file as is.
        #expect(HookStateStore.merge(hook: nil, fileStatus: "busy", fileUpdated: t) == ("busy", false))
    }

    @Test func permissionHoldsUntilBusyAgain() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        let prompt = HookStateRecord(state: .permission, at: t.timeIntervalSince1970)
        // Claude Code reports the prompt as idle, a moment later: still "needs permission".
        #expect(HookStateStore.merge(hook: prompt, fileStatus: "idle", fileUpdated: t.addingTimeInterval(2)) == ("waiting", true))
        // Approved: Claude Code goes busy afterwards.
        #expect(HookStateStore.merge(hook: prompt, fileStatus: "busy", fileUpdated: t.addingTimeInterval(5)) == ("busy", false))
        // An old busy status from before the prompt doesn't clear it.
        #expect(HookStateStore.merge(hook: prompt, fileStatus: "busy", fileUpdated: t.addingTimeInterval(-5)) == ("waiting", true))
    }

    @Test func settingsFileRoundTripWithBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudebar-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        #expect(try ClaudeSettingsFile.load(url).isEmpty) // missing → empty

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: url)
        try ClaudeSettingsFile.save(HookInstaller.install(into: try ClaudeSettingsFile.load(url), helper: helper, stateDir: stateDir), to: url)
        #expect(try String(contentsOf: dir.appendingPathComponent("settings.json.claudebar-backup"), encoding: .utf8) == #"{"model":"opus"}"#)
        #expect(HookInstaller.status(of: try ClaudeSettingsFile.load(url), helper: helper, stateDir: stateDir) == .installed)

        // A file that isn't valid JSON is refused, not overwritten.
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: ClaudeSettingsFile.FileError.self) { try ClaudeSettingsFile.load(url) }
    }
}

/// Opt-in check against a real settings.json copy: `CLAUDEBAR_SETTINGS_SAMPLE=<copy> swift test --filter RealSettings`.
@Suite("Real settings sample", .enabled(if: ProcessInfo.processInfo.environment["CLAUDEBAR_SETTINGS_SAMPLE"] != nil))
struct RealSettingsTests {
    @Test func installThenUninstallLeavesTheFileEquivalent() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDEBAR_SETTINGS_SAMPLE"]!)
        let original = try ClaudeSettingsFile.load(url)
        let installed = HookInstaller.install(into: original, helper: "/A/claudebar-hook", stateDir: "/S")
        try ClaudeSettingsFile.save(installed, to: url)
        let reloaded = try ClaudeSettingsFile.load(url)
        #expect(HookInstaller.status(of: reloaded, helper: "/A/claudebar-hook", stateDir: "/S") == .installed)
        let back = HookInstaller.uninstall(from: reloaded)
        let a = try JSONSerialization.data(withJSONObject: back, options: [.sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        #expect(a == b)
    }
}
