import Foundation

extension KeyCombination {
    /// Parses what a person or a settings file would write: "Ctrl+Alt+Space".
    ///
    /// Generous about spelling because there are three vocabularies in play —
    /// the user's, macOS's ("Option", "Command") and the one older
    /// configurations used ("Super", "Meta") — and none of them is wrong. The
    /// separator may be `+` or `-`, since a key written as "Control-Space" is
    /// what Apple's own documentation looks like.
    public init?(parsing text: String) {
        let tokens = text
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            // Spaces removed inside a token as well as around it, so that the
            // names with one in them — "Fare 4", "Orta Tık" — survive being
            // written out and read back.
            .map { String($0).trimmed.lowercased().replacing(" ", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var modifiers: Modifiers = []
        var key: String?

        for token in tokens {
            if let modifier = Modifiers(name: token) {
                // Repeating a modifier is harmless and says nothing new, so it
                // is accepted rather than rejected.
                modifiers.insert(modifier)
            } else if key == nil {
                key = Self.canonicalKeyName(token)
            } else {
                // Two ordinary keys is not a combination anybody can press.
                return nil
            }
        }

        guard let key, !key.isEmpty else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    /// One canonical spelling, so that two settings files holding the same key
    /// look the same and a round trip through `init(parsing:)` is lossless.
    ///
    /// The order is the order the modifiers are written in on macOS, not the
    /// order they were typed in.
    public var displayName: String {
        (modifiers.canonicalNames + [readableKey]).joined(separator: "+")
    }

    /// The name a mouse button is stored under, whatever it was written as —
    /// the English spellings included, though the display name is Turkish.
    private static func canonicalKeyName(_ token: String) -> String {
        switch token {
        case "middleclick", "middlebutton", "mousemiddle", "ortatık", "ortatik": "mouse3"
        case let fare where fare.hasPrefix("fare") && Int(fare.dropFirst(4)) != nil:
            "mouse" + fare.dropFirst(4)
        default: token
        }
    }

    private var readableKey: String {
        if let button = mouseButton {
            // Named where it has a name. "Fare 3" is the middle one on every
            // mouse there is, and calling it that is friendlier than a number.
            return button == 3 ? "Orta Tık" : "Fare \(button)"
        }
        return key.capitalizedKeyName
    }
}

extension KeyCombination.Modifiers {
    fileprivate init?(name: String) {
        switch name {
        case "ctrl", "control": self = .control
        case "alt", "opt", "option": self = .option
        case "shift": self = .shift
        case "cmd", "command", "meta", "super": self = .command
        default: return nil
        }
    }

    fileprivate var canonicalNames: [String] {
        var names: [String] = []
        if contains(.control) { names.append("Ctrl") }
        if contains(.option)  { names.append("Alt") }
        if contains(.shift)   { names.append("Shift") }
        if contains(.command) { names.append("Cmd") }
        return names
    }
}

extension String {
    /// "space" → "Space", "f13" → "F13", "d" → "D".
    fileprivate var capitalizedKeyName: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
