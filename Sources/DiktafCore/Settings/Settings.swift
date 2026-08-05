import Foundation

/// How the cleaned-up text gets into the window the user was typing in.
public enum DeliveryMode: String, Codable, Sendable, CaseIterable {
    /// Onto the clipboard, then Cmd+V. Fast, and the usual choice.
    case paste
    /// Typed out. Slower, but it leaves the clipboard alone and works in the
    /// places that refuse a paste.
    case type
    /// Onto the clipboard and no further. For when the user wants to decide
    /// where it lands.
    case clipboardOnly
}

/// Everything the settings window holds.
///
/// Decoding is deliberately forgiving: every property has a default and is read
/// with `decodeIfPresent`, so a file written by an older version loads with the
/// new keys at their defaults rather than throwing the user's whole
/// configuration away. That is the only kind of migration this needs, and it
/// keeps working without anybody remembering to write one.
public struct Settings: Codable, Sendable, Equatable {
    /// BCP-47, as in "tr-TR". Nil follows whatever the system is set to.
    public var language: String?

    /// Whether a transcript is cleaned up before it is delivered. Off means the
    /// recogniser's raw output is pasted, which is a reasonable way to work and
    /// the only way to work with no agent installed.
    public var cleanupEnabled: Bool

    public var rules: CleanupRuleSet
    public var delivery: DeliveryMode
    public var bindings: [HotkeyBinding]

    /// Whether the agent key is offered at all.
    public var agentEnabled: Bool

    /// Whether the indicator appears while recording.
    public var showOverlay: Bool

    /// How long cleanup may take before the raw transcript is delivered
    /// instead. A dictation is worth waiting a few seconds for and no longer:
    /// past that the user has already started typing it out by hand.
    public var refinerTimeoutSeconds: Int

    /// Which model the agent should use, or nil for its own default.
    public var agentModel: String?

    public init(
        language: String? = nil,
        cleanupEnabled: Bool = true,
        rules: CleanupRuleSet = .recommended,
        delivery: DeliveryMode = .paste,
        bindings: [HotkeyBinding] = Settings.defaultBindings,
        agentEnabled: Bool = true,
        showOverlay: Bool = true,
        refinerTimeoutSeconds: Int = 20,
        agentModel: String? = nil
    ) {
        self.language = language
        self.cleanupEnabled = cleanupEnabled
        self.rules = rules
        self.delivery = delivery
        self.bindings = bindings
        self.agentEnabled = agentEnabled
        self.showOverlay = showOverlay
        self.refinerTimeoutSeconds = refinerTimeoutSeconds
        self.agentModel = agentModel
    }

    public static let defaults = Settings()

    /// Ctrl+Alt rather than plain Ctrl, and not for taste: Ctrl+Space is the
    /// input source switcher on macOS, so a key registered there never arrives
    /// — the dictation simply does not start, with nothing to say why.
    public static let defaultBindings: [HotkeyBinding] = [
        HotkeyBinding(action: .toggle,
                      combination: KeyCombination(key: "space", modifiers: [.control, .option])),
        HotkeyBinding(action: .cancel,
                      combination: KeyCombination(key: "d", modifiers: [.control, .option])),
        HotkeyBinding(action: .agent,
                      combination: KeyCombination(key: "a", modifiers: [.control, .option])),
    ]

    public func combination(for action: HotkeyAction) -> KeyCombination? {
        bindings.first { $0.action == action }?.combination
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case language, cleanupEnabled, rules, delivery, bindings
        case agentEnabled, showOverlay, refinerTimeoutSeconds, agentModel
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings.defaults
        language = try box.decodeIfPresent(String.self, forKey: .language)
        cleanupEnabled = try box.decodeIfPresent(Bool.self, forKey: .cleanupEnabled)
            ?? fallback.cleanupEnabled
        rules = try box.decodeIfPresent(CleanupRuleSet.self, forKey: .rules)
            ?? fallback.rules
        delivery = try box.decodeIfPresent(DeliveryMode.self, forKey: .delivery)
            ?? fallback.delivery
        bindings = try box.decodeIfPresent([HotkeyBinding].self, forKey: .bindings)
            ?? fallback.bindings
        agentEnabled = try box.decodeIfPresent(Bool.self, forKey: .agentEnabled)
            ?? fallback.agentEnabled
        showOverlay = try box.decodeIfPresent(Bool.self, forKey: .showOverlay)
            ?? fallback.showOverlay
        refinerTimeoutSeconds = try box.decodeIfPresent(Int.self, forKey: .refinerTimeoutSeconds)
            ?? fallback.refinerTimeoutSeconds
        agentModel = try box.decodeIfPresent(String.self, forKey: .agentModel)
    }
}
