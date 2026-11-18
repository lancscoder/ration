import Foundation

/// A global keyboard shortcut, stored as the virtual key code plus modifiers.
///
/// Modifiers use the `NSEvent.ModifierFlags` bit values so the app can pass
/// `event.modifierFlags.rawValue` straight in; `carbonModifiers` converts them
/// for `RegisterEventHotKey`. (Plain numbers keep this file free of AppKit/Carbon.)
public struct HotKeyShortcut: Codable, Sendable, Equatable {
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
    static let relevant: UInt = shift | control | option | command

    public var keyCode: UInt32
    public var modifiers: UInt
    /// What the key shows as, captured when recording (e.g. "C", "Space", "F5").
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.relevant
        self.key = key
    }

    /// A global shortcut needs ⌘, ⌃ or ⌥, otherwise it would swallow ordinary typing.
    public var isValid: Bool { modifiers & (Self.command | Self.control | Self.option) != 0 && !key.isEmpty }

    /// e.g. `⌃⌥C`, in the standard macOS modifier order.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + key
    }

    /// Carbon `cmdKey`/`shiftKey`/`optionKey`/`controlKey` bits.
    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers & Self.command != 0 { m |= 1 << 8 }
        if modifiers & Self.shift != 0 { m |= 1 << 9 }
        if modifiers & Self.option != 0 { m |= 1 << 11 }
        if modifiers & Self.control != 0 { m |= 1 << 12 }
        return m
    }

    /// Display name for a key from its virtual key code, falling back to the typed characters.
    public static func keyName(keyCode: UInt16, characters: String?) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[keyCode] { return name }
        return (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: Storage

    public func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ string: String?) -> HotKeyShortcut? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
    }
}
