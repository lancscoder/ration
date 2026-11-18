import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Cache folder")
struct AppPathsTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "claudebar-tests-\(UUID().uuidString)"
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
            d.set("~/Somewhere/ClaudeBar", forKey: AppPaths.cacheDirectoryKey)
            #expect(AppPaths.cacheDirectory(defaults: d).path == NSHomeDirectory() + "/Somewhere/ClaudeBar")
        }
    }

    @Test func movesOnlyOwnFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("claudebar-\(UUID().uuidString)")
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
}
