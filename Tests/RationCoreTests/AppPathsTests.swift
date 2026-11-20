import Foundation
import Testing
@testable import RationCore

@Suite("Cache folder")
struct AppPathsTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ration-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsWhenUnsetOrBlank() throws {
        try withDefaults { d in
            #expect(AppPaths.cacheDirectory(defaults: d) == AppPaths.defaultCacheDirectory)
            d.set("  ", forKey: AppPaths.cacheDirectoryKey)
            #expect(AppPaths.cacheDirectory(defaults: d) == AppPaths.defaultCacheDirectory)
        }
    }

    @Test func usesOverrideAndExpandsTilde() throws {
        try withDefaults { d in
            d.set("~/Somewhere/Ration", forKey: AppPaths.cacheDirectoryKey)
            #expect(AppPaths.cacheDirectory(defaults: d).path == NSHomeDirectory() + "/Somewhere/Ration")
        }
    }

    @Test func movesOnlyOwnFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new/nested")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("u".utf8).write(to: old.appendingPathComponent("usage.json"))
        try Data("t".utf8).write(to: old.appendingPathComponent("tokens.json"))
        try Data("x".utf8).write(to: old.appendingPathComponent("unrelated.txt"))

        try AppPaths.moveCacheFiles(from: old, to: new)

        #expect(try String(contentsOf: new.appendingPathComponent("usage.json"), encoding: .utf8) == "u")
        #expect(fm.fileExists(atPath: new.appendingPathComponent("tokens.json").path))
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("usage.json").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("unrelated.txt").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("unrelated.txt").path))
    }

    @Test func claudeFolderOverrideReplacesAutoDetection() throws {
        try withDefaults { d in
            #expect(AppPaths.claudeFolderOverride(defaults: d) == nil)
            #expect(AppPaths.configDir(defaults: d, environment: ["CLAUDE_CONFIG_DIR": "/env/dir"]) == "/env/dir")
            d.set("~/work/.claude", forKey: AppPaths.claudeFolderKey)
            let override = try #require(AppPaths.claudeFolderOverride(defaults: d))
            #expect(override.path == NSHomeDirectory() + "/work/.claude")
            #expect(AppPaths.configDir(defaults: d, environment: ["CLAUDE_CONFIG_DIR": "/env/dir"]) == override.path)
            #expect(AppPaths.claudeRoots(configDir: "/env/dir", override: override) == [override])
        }
    }

    @Test func recognisesClaudeFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!AppPaths.looksLikeClaudeFolder(root))
        try fm.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        #expect(AppPaths.looksLikeClaudeFolder(root))
    }
}
