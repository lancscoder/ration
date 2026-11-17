import Foundation

public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "local.claudebar.ClaudeBar"
}

public enum AppPaths {
    /// `~/Library/Caches/<bundle-id>`
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(Log.subsystem, isDirectory: true)
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
