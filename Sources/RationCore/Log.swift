import Foundation

public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.lancscoder.ration"
}

public enum AppPaths {
    /// UserDefaults key holding a user-chosen cache folder (absolute path).
    public static let cacheDirectoryKey = "cacheDirectoryOverride"

    /// Files Ration keeps in its cache folder (moved when the folder changes).
    public static let cacheFileNames = ["usage.json", "quota-samples.json", "tokens.json"]

    /// `~/Library/Caches/<bundle-id>`
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(Log.subsystem, isDirectory: true)
    }

    /// The user's chosen cache folder, or the default. Read at launch; a change needs a relaunch.
    public static var cacheDirectory: URL { cacheDirectory(defaults: .standard) }

    public static func cacheDirectory(defaults: UserDefaults) -> URL {
        if let path = defaults.string(forKey: cacheDirectoryKey)?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return defaultCacheDirectory
    }

    /// Moves Ration's cache files from `old` to `new` (replacing any there) and creates `new`.
    /// Leaves unrelated files alone, so pointing at an existing folder is safe.
    public static func moveCacheFiles(from old: URL, to new: URL, fileManager fm: FileManager = .default) throws {
        guard old.standardizedFileURL != new.standardizedFileURL else { return }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in cacheFileNames {
            let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: src, to: dst)
        }
    }

    /// Where `ration-hook` records session states:
    /// `~/Library/Application Support/<bundle-id>/hook-state`. Not in the cache
    /// folder, so moving the cache doesn't break installed hooks.
    public static var hookStateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Log.subsystem, isDirectory: true).appendingPathComponent("hook-state", isDirectory: true)
    }

    /// UserDefaults key holding a user-chosen Claude Code folder (absolute path).
    public static let claudeFolderKey = "claudeFolderOverride"

    /// The Claude Code folder the user picked in Settings, if any.
    public static func claudeFolderOverride(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: claudeFolderKey)?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// The config dir to use for credentials: the Settings override, else `CLAUDE_CONFIG_DIR`.
    public static func configDir(defaults: UserDefaults = .standard,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        claudeFolderOverride(defaults: defaults)?.path ?? environment["CLAUDE_CONFIG_DIR"]
    }

    /// Whether a folder looks like a Claude Code config folder (has logs or session files).
    public static func looksLikeClaudeFolder(_ url: URL) -> Bool {
        ["projects", "sessions"].contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Root Claude Code config directories to scan (deduplicated, existing only).
    /// A folder chosen in Settings replaces auto-detection entirely.
    public static func claudeRoots(configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
                                   override: URL? = claudeFolderOverride()) -> [URL] {
        if let override { return [override] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let configDir, !configDir.isEmpty {
            candidates.append(URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath))
        }
        candidates.append(home.appendingPathComponent(".claude"))
        candidates.append(home.appendingPathComponent(".config/claude"))
        var seen = Set<String>()
        return candidates.filter { url in
            let p = url.standardizedFileURL.path
            guard !seen.contains(p) else { return false }
            seen.insert(p)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
