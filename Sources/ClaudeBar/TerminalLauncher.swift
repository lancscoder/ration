import AppKit
import ClaudeBarCore
import Foundation
import os

/// Opens the chosen terminal in a session's directory running `claude --resume <id>`.
///
/// Terminal.app and iTerm2 are handed a generated `.command` script (no
/// AppleScript, so no Automation permission prompt). Ghostty gets `-e <script>`.
/// A custom command template can use `{script}`, `{cwd}`, `{sessionId}` and `{command}`.
enum TerminalLauncher {
    private static let log = Logger(subsystem: Log.subsystem, category: "terminal")

    enum LaunchError: LocalizedError {
        case badSession
        case missingDirectory(String)
        case appNotInstalled(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .badSession: return "This session can't be resumed."
            case .missingDirectory(let d): return "Project folder not found: \(d)"
            case .appNotInstalled(let a): return "\(a) is not installed."
            case .commandFailed(let m): return m
            }
        }
    }

    static func resume(sessionId: String, cwd: String?, choice: TerminalChoice, customTemplate: String) throws {
        guard ResumeCommand.isSafeSessionId(sessionId) else { throw LaunchError.badSession }
        let dir = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw LaunchError.missingDirectory(dir)
        }
        let script = try writeScript(cwd: dir, sessionId: sessionId)

        switch choice {
        case .terminal, .iterm:
            guard let bundleID = choice.bundleID,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw LaunchError.appNotInstalled(choice.title)
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: config) { _, error in
                if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
            }
        case .ghostty:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
                throw LaunchError.appNotInstalled("Ghostty")
            }
            try run("/usr/bin/open", ["-na", appURL.path, "--args", "--working-directory=\(dir)", "-e", script.path])
        case .custom:
            let template = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !template.isEmpty else { throw LaunchError.commandFailed("Set a custom terminal command in Settings.") }
            let command = ResumeCommand.expand(template: template, cwd: dir, sessionId: sessionId, scriptPath: script.path)
            try run("/bin/zsh", ["-lc", command])
        }
    }

    private static func writeScript(cwd: String, sessionId: String) throws -> URL {
        guard let body = ResumeCommand.script(cwd: cwd, sessionId: sessionId) else { throw LaunchError.badSession }
        let dir = AppPaths.cacheDirectory.appendingPathComponent("resume", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude-resume-\(sessionId).command")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw LaunchError.commandFailed(error.localizedDescription) }
    }
}
