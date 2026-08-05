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
            .map { String($0).trimmed.lowercased() }
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
                key = token
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
        (modifiers.canonicalNames + [key.capitalizedKeyName]).joined(separator: "+")
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
