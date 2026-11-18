import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Global shortcut")
struct HotKeyShortcutTests {
    let ctrlOptC = HotKeyShortcut(keyCode: 8, modifiers: HotKeyShortcut.control | HotKeyShortcut.option, key: "C")

    @Test func displaysInMacOSModifierOrder() {
        let all = HotKeyShortcut(keyCode: 8, modifiers: HotKeyShortcut.command | HotKeyShortcut.shift | HotKeyShortcut.option | HotKeyShortcut.control, key: "C")
        #expect(all.display == "⌃⌥⇧⌘C")
        #expect(ctrlOptC.display == "⌃⌥C")
    }

    @Test func convertsToCarbonModifiers() {
        #expect(ctrlOptC.carbonModifiers == (1 << 12) | (1 << 11))
        #expect(HotKeyShortcut(keyCode: 49, modifiers: HotKeyShortcut.command | HotKeyShortcut.shift, key: "Space").carbonModifiers == (1 << 8) | (1 << 9))
    }

    @Test func needsACommandControlOrOptionModifier() {
        #expect(ctrlOptC.isValid)
        #expect(!HotKeyShortcut(keyCode: 8, modifiers: HotKeyShortcut.shift, key: "C").isValid)
        #expect(!HotKeyShortcut(keyCode: 8, modifiers: 0, key: "C").isValid)
    }

    @Test func dropsIrrelevantModifierBits() {
        let capsLockAndFn: UInt = (1 << 16) | (1 << 23)
        #expect(HotKeyShortcut(keyCode: 8, modifiers: HotKeyShortcut.control | capsLockAndFn, key: "C").modifiers == HotKeyShortcut.control)
    }

    @Test func namesSpecialKeys() {
        #expect(HotKeyShortcut.keyName(keyCode: 49, characters: " ") == "Space")
        #expect(HotKeyShortcut.keyName(keyCode: 96, characters: nil) == "F5")
        #expect(HotKeyShortcut.keyName(keyCode: 8, characters: "c") == "C")
    }

    @Test func roundTripsThroughStorage() throws {
        let text = try #require(ctrlOptC.encoded())
        #expect(HotKeyShortcut.decode(text) == ctrlOptC)
        #expect(HotKeyShortcut.decode(nil) == nil)
        #expect(HotKeyShortcut.decode("garbage") == nil)
    }
}
