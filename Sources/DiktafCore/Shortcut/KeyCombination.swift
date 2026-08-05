import Foundation

/// A key and the modifiers held with it, as the settings store it.
///
/// Kept as a portable description rather than a platform key code: the codes
/// differ between platforms and even between the two APIs macOS uses for them,
/// so the translation belongs in the adapter that registers the key. What
/// travels is what the user chose.
public struct KeyCombination: Sendable, Equatable, Hashable, Codable {
    /// The key itself, lowercased and unabbreviated: "space", "d", "f13".
    public let key: String

    /// Held with it. An ordered set in spirit; order never matters for equality
    /// because the modifiers are stored as an option set.
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// A mouse button, written as the key. `KeyCombination(key: "mouse4", …)`.
    ///
    /// Carried in the same field as a key rather than in a case of its own so
    /// that everything already written keeps working: the settings file, the
    /// equality, the `HotkeyBinding`, the port. What differs is only who can
    /// register it, and that is the platform's problem.
    ///
    /// Buttons start at 3. The left and right buttons are 1 and 2, and binding
    /// either of them would take the mouse away from the user everywhere — so
    /// they are not offered.
    public static func mouseButton(_ number: Int, modifiers: Modifiers = []) -> KeyCombination {
        KeyCombination(key: "mouse\(number)", modifiers: modifiers)
    }

    /// Which mouse button this is, or nil if it is a key.
    public var mouseButton: Int? {
        guard key.hasPrefix("mouse"), let number = Int(key.dropFirst(5)) else { return nil }
        return number >= 3 ? number : nil
    }

    public var isMouseButton: Bool { mouseButton != nil }

    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option  = Modifiers(rawValue: 1 << 1)
        public static let shift   = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }
}
