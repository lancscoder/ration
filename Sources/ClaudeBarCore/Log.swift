import Foundation

public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "local.claudebar.ClaudeBar"
}

public enum AppPaths {
    /// UserDefaults key holding a user-chosen cache folder (absolute path).
    public static let cacheDirectoryKey = "cacheDirectoryOverride"

    /// Files ClaudeBar keeps in its cache folder (moved when the folder changes).
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

    /// Moves ClaudeBar's cache files from `old` to `new` (replacing any there) and creates `new`.
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

    /// Root Claude Code config directories to scan (deduplicated, existing only).
    public static func claudeRoots(configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) -> [URL] {
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
