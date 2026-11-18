import AppKit
import ClaudeBarCore
import Foundation
import os
import UniformTypeIdentifiers

/// Finds terminal apps on this Mac: the ones in `TerminalCatalog.known`, plus any
/// other app that registers as a Shell for shell scripts.
@MainActor
enum TerminalDiscovery {
    static func installed() -> [TerminalApp] {
        var found: [TerminalApp] = []
        var seen = Set<String>()
        for known in TerminalCatalog.known {
            guard let url = locate(known) else { continue }
            found.append(TerminalApp(id: known.bundleID, name: known.name, method: known.method, appURL: url))
            seen.insert(known.bundleID)
            if let real = Bundle(url: url)?.bundleIdentifier { seen.insert(real) }
        }

        var others: [TerminalApp] = []
        if let type = UTType("com.apple.terminal.shell-script") {
            for url in NSWorkspace.shared.urlsForApplications(toOpen: type) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !seen.contains(id), id != Bundle.main.bundleIdentifier,
                      let docTypes = bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]],
                      TerminalCatalog.isShellHandler(documentTypes: docTypes) else { continue }
                seen.insert(id)
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                others.append(TerminalApp(id: id, name: name, method: .openScript, appURL: url))
            }
        }
        return found + others.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app for a saved setting, if it's installed.
    static func app(id: String) -> TerminalApp? {
        if let known = TerminalCatalog.known(bundleID: id) {
            return locate(known).map { TerminalApp(id: id, name: known.name, method: known.method, appURL: $0) }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return TerminalApp(id: id, name: name, method: .openScript, appURL: url)
    }

    static func displayName(id: String) -> String {
        TerminalCatalog.known(bundleID: id)?.name ?? app(id: id)?.name ?? id
    }

    private static func locate(_ known: TerminalCatalog.Known) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID) { return url }
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Setapp"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for dir in dirs {
            for name in known.appNames {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

/// Opens the chosen terminal in a session's directory running `claude --resume <id>`.
///
/// Apps that run shell scripts get a generated `.command` file (no AppleScript, so
/// no Automation prompt). Apps with a documented CLI get `open -na … --args`. Apps
/// that can't be told to run anything are opened and the command is copied to paste.
/// A custom command template can use `{script}`, `{cwd}`, `{sessionId}` and `{command}`.
@MainActor
enum TerminalLauncher {
    nonisolated private static let log = Logger(subsystem: Log.subsystem, category: "terminal")

    enum Outcome: Equatable {
        case launched
        /// The command is on the clipboard; the user pastes it into this app.
        case copiedCommand(appName: String)
    }

    enum LaunchError: LocalizedError {
        case badSession
        case missingDirectory(String)
        case appNotInstalled(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .badSession: return "This session can't be resumed."
            case .missingDirectory(let d): return "Project folder not found: \(d)"
            case .appNotInstalled(let a): return "\(a) is not installed. Choose another terminal in Settings."
            case .commandFailed(let m): return m
            }
        }
    }

    static func resume(sessionId: String, cwd: String?, terminalID: String, customTemplate: String) throws -> Outcome {
        guard ResumeCommand.isSafeSessionId(sessionId) else { throw LaunchError.badSession }
        let dir = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw LaunchError.missingDirectory(dir)
        }

        if terminalID == TerminalCatalog.customID {
            let template = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !template.isEmpty else { throw LaunchError.commandFailed("Set a custom terminal command in Settings.") }
            let script = try writeScript(cwd: dir, sessionId: sessionId)
            try run("/bin/zsh", ["-lc", ResumeCommand.expand(template: template, cwd: dir, sessionId: sessionId, scriptPath: script.path)])
            return .launched
        }

        guard let app = TerminalDiscovery.app(id: terminalID), let appURL = app.appURL else {
            throw LaunchError.appNotInstalled(TerminalDiscovery.displayName(id: terminalID))
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        switch app.method {
        case .openScript:
            let script = try writeScript(cwd: dir, sessionId: sessionId)
            NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: config) { _, error in
                if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
            }
            return .launched

        case .openArgs(let args):
            let script = try writeScript(cwd: dir, sessionId: sessionId)
            try run("/usr/bin/open", ["-na", appURL.path, "--args"] + TerminalCatalog.expand(args: args, cwd: dir, script: script.path))
            return .launched

        case .pasteCommand(let opensFolder):
            guard let command = TerminalCatalog.pasteCommand(cwd: dir, sessionId: sessionId) else { throw LaunchError.badSession }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            if opensFolder {
                NSWorkspace.shared.open([URL(fileURLWithPath: dir, isDirectory: true)], withApplicationAt: appURL, configuration: config) { _, error in
                    if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
                }
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                    if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
                }
            }
            return .copiedCommand(appName: app.name)
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
