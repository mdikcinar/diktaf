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
/// on its own, so a file written by an older version loads with the new keys at
/// their defaults rather than throwing the user's whole configuration away.
/// That is the only kind of migration this needs, and it keeps working without
/// anybody remembering to write one. A value that is there but cannot be read —
/// a typo in an enum, a string where a number goes — costs only that key, and a
/// shortcut or rule that cannot be read costs only itself.
public struct Settings: Codable, Sendable, Equatable {
    /// BCP-47, as in "tr-TR". Nil follows whatever the system is set to.
    public var language: String?

    /// Which recogniser does the listening.
    public var engine: TranscriptionEngine

    /// Which set of Whisper weights, when `engine` is `.whisper`. Nil takes the
    /// catalogue's own recommendation, which is what almost everybody wants.
    ///
    /// A string rather than an enum for the same reason `cleanupModel` is one:
    /// the names belong to the repository the weights come from, not to the
    /// domain, and a name this does not recognise is shown rather than replaced.
    public var whisperModel: String?

    /// Whether a transcript is cleaned up before it is delivered. Off means the
    /// recogniser's raw output is pasted, which is a reasonable way to work and
    /// the only way to work with no agent installed.
    public var cleanupEnabled: Bool

    /// Which agent does the cleaning up.
    public var cleanupEngine: CleanupEngine

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

    /// Whether a dictation ends by itself once the speaker has gone quiet.
    public var silenceStopEnabled: Bool

    /// How long the quiet has to last, counted from the last word. Long enough
    /// to take a breath in, short enough that waiting for it beats reaching
    /// for the key.
    public var silenceStopSeconds: Double

    /// Which Claude model cleans up a transcript when `cleanupEngine` is
    /// `.claude`, or nil for the command's own default.
    ///
    /// Separate from `agentModel` because the two jobs want opposite things.
    /// Cleaning up one sentence happens on every dictation and is worth being
    /// fast and cheap; answering a question happens when asked and is worth
    /// being good. Sharing one setting meant either paying for the large model
    /// on every sentence or asking the small one to reason.
    public var cleanupModel: String?

    /// Which Ollama model cleans up a transcript when `cleanupEngine` is
    /// `.ollama`, or nil for the adapter's own recommendation.
    ///
    /// A string for the same reason `cleanupModel` and `whisperModel` are: the
    /// names belong to whoever serves the model, not to the domain.
    public var ollamaModel: String?

    /// Which model answers when you ask the agent something, or nil for the
    /// command's own default.
    public var agentModel: String?

    public init(
        language: String? = nil,
        engine: TranscriptionEngine = .system,
        whisperModel: String? = nil,
        cleanupEnabled: Bool = true,
        cleanupEngine: CleanupEngine = .ollama,
        rules: CleanupRuleSet = .recommended,
        delivery: DeliveryMode = .paste,
        bindings: [HotkeyBinding] = Settings.defaultBindings,
        agentEnabled: Bool = true,
        showOverlay: Bool = true,
        refinerTimeoutSeconds: Int = 20,
        silenceStopEnabled: Bool = true,
        silenceStopSeconds: Double = 2.5,
        cleanupModel: String? = "haiku",
        ollamaModel: String? = nil,
        agentModel: String? = nil
    ) {
        self.language = language
        self.engine = engine
        self.whisperModel = whisperModel
        self.cleanupEnabled = cleanupEnabled
        self.cleanupEngine = cleanupEngine
        self.rules = rules
        self.delivery = delivery
        self.bindings = bindings
        self.agentEnabled = agentEnabled
        self.showOverlay = showOverlay
        self.refinerTimeoutSeconds = refinerTimeoutSeconds
        self.silenceStopEnabled = silenceStopEnabled
        self.silenceStopSeconds = silenceStopSeconds
        self.cleanupModel = cleanupModel
        self.ollamaModel = ollamaModel
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
        case language, engine, whisperModel, cleanupEnabled, cleanupEngine, rules
        case delivery, bindings, agentEnabled, showOverlay, refinerTimeoutSeconds
        case silenceStopEnabled, silenceStopSeconds
        case cleanupModel, ollamaModel, agentModel
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings.defaults
        language = try? box.decodeIfPresent(String.self, forKey: .language)
        // Absent in a file written before there was a second recogniser, and
        // absent is the one that needs no download — so an upgrade changes
        // nothing about how the next dictation works.
        engine = (try? box.decodeIfPresent(TranscriptionEngine.self, forKey: .engine))
            ?? fallback.engine
        whisperModel = try? box.decodeIfPresent(String.self, forKey: .whisperModel)
        cleanupEnabled = (try? box.decodeIfPresent(Bool.self, forKey: .cleanupEnabled))
            ?? fallback.cleanupEnabled
        cleanupEngine = (try? box.decodeIfPresent(CleanupEngine.self, forKey: .cleanupEngine))
            ?? fallback.cleanupEngine
        rules = (try? box.decodeIfPresent(CleanupRuleSet.self, forKey: .rules))
            ?? fallback.rules
        delivery = (try? box.decodeIfPresent(DeliveryMode.self, forKey: .delivery))
            ?? fallback.delivery
        bindings = (try? box.decodeIfPresent([Forgiving<HotkeyBinding>].self, forKey: .bindings))?
            .compactMap(\.value) ?? fallback.bindings
        agentEnabled = (try? box.decodeIfPresent(Bool.self, forKey: .agentEnabled))
            ?? fallback.agentEnabled
        showOverlay = (try? box.decodeIfPresent(Bool.self, forKey: .showOverlay))
            ?? fallback.showOverlay
        refinerTimeoutSeconds = (try? box.decodeIfPresent(Int.self, forKey: .refinerTimeoutSeconds))
            ?? fallback.refinerTimeoutSeconds
        silenceStopEnabled = (try? box.decodeIfPresent(Bool.self, forKey: .silenceStopEnabled))
            ?? fallback.silenceStopEnabled
        silenceStopSeconds = (try? box.decodeIfPresent(Double.self, forKey: .silenceStopSeconds))
            ?? fallback.silenceStopSeconds
        // Absent in a file written before the two were told apart, in which case
        // the default is what it always effectively was.
        cleanupModel = (try? box.decodeIfPresent(String.self, forKey: .cleanupModel))
            ?? fallback.cleanupModel
        ollamaModel = try? box.decodeIfPresent(String.self, forKey: .ollamaModel)
        agentModel = try? box.decodeIfPresent(String.self, forKey: .agentModel)
    }
}
