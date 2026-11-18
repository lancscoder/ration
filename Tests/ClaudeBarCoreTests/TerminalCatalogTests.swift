import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Terminal catalog")
struct TerminalCatalogTests {
    @Test func migratesOldSettingValues() {
        #expect(TerminalCatalog.migrate(nil) == "com.apple.Terminal")
        #expect(TerminalCatalog.migrate("terminal") == "com.apple.Terminal")
        #expect(TerminalCatalog.migrate("iterm") == "com.googlecode.iterm2")
        #expect(TerminalCatalog.migrate("ghostty") == "com.mitchellh.ghostty")
        #expect(TerminalCatalog.migrate("custom") == "custom")
        #expect(TerminalCatalog.migrate("com.cmuxterm.app") == "com.cmuxterm.app")
        #expect(TerminalCatalog.migrate("dev.herdr.app") == "com.apple.Terminal")
        #expect(TerminalCatalog.migrate("com.superlogical.rex") == "com.apple.Terminal")
    }

    @Test func knownIDsAreUnique() {
        let ids = TerminalCatalog.known.map(\.bundleID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func recognisesShellHandlersOnly() {
        // cmux / Warp style
        #expect(TerminalCatalog.isShellHandler(documentTypes: [
            ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["com.apple.terminal.shell-script"]],
        ]))
        // iTerm2 style: extension-based
        #expect(TerminalCatalog.isShellHandler(documentTypes: [
            ["CFBundleTypeRole": "Shell", "CFBundleTypeExtensions": ["command", "sh"]],
        ]))
        // An editor that opens scripts is not a terminal
        #expect(!TerminalCatalog.isShellHandler(documentTypes: [
            ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["com.apple.terminal.shell-script"]],
        ]))
        // A shell for folders only (no scripts)
        #expect(!TerminalCatalog.isShellHandler(documentTypes: [
            ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.folder"]],
        ]))
    }

    @Test func expandsArgsWithoutQuoting() {
        let args = TerminalCatalog.expand(args: ["--working-directory={cwd}", "-e", "{script}"],
                                          cwd: "/Users/me/My Project", script: "/tmp/x.command")
        #expect(args == ["--working-directory=/Users/me/My Project", "-e", "/tmp/x.command"])
    }

    @Test func pasteCommandQuotesFolderAndRejectsBadIds() {
        let id = "8c2f6a1e-1111-4222-8333-944455556666"
        #expect(TerminalCatalog.pasteCommand(cwd: "/Users/me/it's here", sessionId: id)
                == "cd '/Users/me/it'\\''s here' && claude --resume \(id)")
        #expect(TerminalCatalog.pasteCommand(cwd: "/x", sessionId: "a; rm -rf ~") == nil)
    }
}
