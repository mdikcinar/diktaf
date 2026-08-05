import Carbon.HIToolbox
import CoreGraphics
import DiktafCore

/// The one place that turns a `KeyCombination` into the numbers macOS wants.
///
/// There are two sets of numbers and they are not interchangeable. Carbon's
/// modifier constants (`cmdKey`, `optionKey`, …) are what `RegisterEventHotKey`
/// takes; `CGEventFlags` are what a posted key event carries. Mixing them
/// produces a shortcut that registers without complaint and never fires, or a
/// key press that arrives with the wrong modifiers held — both of which look
/// like the application ignoring you.
public enum KeyCodes {

    /// Virtual key codes, which are the same for both APIs.
    ///
    /// Only the keys worth binding a global shortcut to. Letters and digits are
    /// derived; everything else is named, because a user writing "space" in the
    /// settings should not have to know it is 49.
    public static func virtualKey(for name: String) -> CGKeyCode? {
        if let named = named[name] { return named }
        // A single letter or digit, looked up in the same table by its own name.
        if name.count == 1, let single = named[name] { return single }
        return nil
    }

    static let named: [String: CGKeyCode] = {
        var table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,

            "return": 36, "enter": 36,
            "tab": 48,
            "space": 49,
            "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53,
            "forwarddelete": 117,
            "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,

            "equal": 24, "minus": 27, "leftbracket": 33, "rightbracket": 30,
            "quote": 39, "semicolon": 41, "backslash": 42, "comma": 43,
            "slash": 44, "period": 47, "grave": 50,
        ]
        // The function keys, whose codes are not consecutive.
        let functionKeys: [Int: CGKeyCode] = [
            1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100,
            9: 101, 10: 109, 11: 103, 12: 111, 13: 105, 14: 107, 15: 113,
            16: 106, 17: 64, 18: 79, 19: 80, 20: 90,
        ]
        for (number, code) in functionKeys { table["f\(number)"] = code }
        return table
    }()

    /// What `RegisterEventHotKey` takes.
    public static func carbonModifiers(_ modifiers: KeyCombination.Modifiers) -> UInt32 {
        var flags: Int = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option)  { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift)   { flags |= shiftKey }
        return UInt32(flags)
    }

    /// What a posted `CGEvent` carries. Deliberately not the numbers above.
    public static func eventFlags(_ modifiers: KeyCombination.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }
}

extension KeyCodes {
    /// The name to store for a key that was just pressed.
    ///
    /// The reverse of `virtualKey(for:)`, and derived from the same table so the
    /// two cannot drift apart. Built from a key code rather than from the
    /// characters the event carries, because the characters depend on the
    /// keyboard layout and on which modifiers were held — Alt+D on a Turkish
    /// layout does not produce "d", and a shortcut recorded from the character
    /// would only work on the layout it was recorded on.
    public static func portableName(forVirtualKey code: UInt16) -> String? {
        byCode[CGKeyCode(code)]
    }

    private static let byCode: [CGKeyCode: String] = {
        var table: [CGKeyCode: String] = [:]
        for (name, code) in named {
            // The first spelling wins, so "space" is not overwritten by a
            // synonym and "return" does not become "enter".
            if let existing = table[code], existing.count <= name.count { continue }
            table[code] = name
        }
        return table
    }()
}
