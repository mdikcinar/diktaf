import Foundation
import Testing
@testable import DiktafCore

@Suite("Settings")
struct SettingsTests {

    @Test("a full round trip changes nothing")
    func roundTrips() throws {
        var original = Settings.defaults
        original.language = "tr-TR"
        original.delivery = .type
        original.cleanupPrompt = "Keep it short."
        original.cleanupEngine = .claude
        original.ollamaModel = "qwen2.5:7b"
        original.silenceStopEnabled = false
        original.silenceStopSeconds = 4.5

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == original)
    }

    /// The migration this actually needs: a file written before a setting
    /// existed must not cost the user everything else in it.
    @Test("a file from an older version loads with the new keys at their defaults")
    func toleratesMissingKeys() throws {
        let old = Data(#"{"cleanupEnabled":false}"#.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: old)

        #expect(decoded.cleanupEnabled == false)
        #expect(decoded.delivery == Settings.defaults.delivery)
        #expect(decoded.cleanupPrompt == Settings.defaults.cleanupPrompt)
        #expect(decoded.bindings == Settings.defaults.bindings)
        #expect(decoded.silenceStopEnabled == Settings.defaults.silenceStopEnabled)
        #expect(decoded.silenceStopSeconds == Settings.defaults.silenceStopSeconds)
        #expect(decoded.refinerTimeoutSeconds == Settings.defaults.refinerTimeoutSeconds)
    }

    @Test("a file from before the cleanup engine was a choice loads with Ollama")
    func defaultsTheCleanupEngine() throws {
        let old = Data(#"{"cleanupEnabled":true,"cleanupModel":"sonnet"}"#.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: old)

        #expect(decoded.cleanupEngine == .ollama)
        #expect(decoded.ollamaModel == nil)
        #expect(decoded.cleanupModel == "sonnet")
    }

    /// One typo must not cost the user every other setting in the file.
    @Test("a value that cannot be read costs only its own key")
    func toleratesInvalidValues() throws {
        let file = Data(#"""
        {
          "language": "tr-TR",
          "engine": "quantum",
          "cleanupEngine": "gpt",
          "delivery": 42,
          "refinerTimeoutSeconds": "soon",
          "showOverlay": "yes",
          "cleanupEnabled": false,
          "agentModel": ["opus"]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: file)

        #expect(decoded.language == "tr-TR")
        #expect(decoded.cleanupEnabled == false)
        #expect(decoded.engine == Settings.defaults.engine)
        #expect(decoded.cleanupEngine == Settings.defaults.cleanupEngine)
        #expect(decoded.delivery == Settings.defaults.delivery)
        #expect(decoded.refinerTimeoutSeconds == Settings.defaults.refinerTimeoutSeconds)
        #expect(decoded.showOverlay == Settings.defaults.showOverlay)
        #expect(decoded.agentModel == nil)
    }

    /// The rules and the extra instruction were the prompt before there was one
    /// field for it. A file that still has them loads with the shipped prompt,
    /// like any other key this version does not know.
    @Test("a file with the old rules loads with the recommended prompt")
    func ignoresTheOldRules() throws {
        let file = Data(#"{"rules":{"rules":[{"text":"Keep it short."}]},"cleanupEnabled":false}"#.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: file)

        #expect(decoded.cleanupPrompt == CleanupInstruction.recommendedPrompt)
        #expect(decoded.cleanupEnabled == false)
    }

    @Test("a shortcut that cannot be read is dropped and the rest kept")
    func dropsUnreadableElements() throws {
        let file = Data(#"""
        {
          "bindings": [
            {"action": "toggle", "combination": {"key": "f13", "modifiers": 0}},
            {"action": "teleport", "combination": {"key": "t", "modifiers": 1}},
            {"action": "cancel"}
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: file)

        #expect(decoded.bindings == [
            HotkeyBinding(action: .toggle, combination: KeyCombination(key: "f13", modifiers: [])),
        ])
    }

    @Test("a prompt that is not text, or shortcuts that are not a list, fall back to the defaults")
    func replacesUnreadableValues() throws {
        let file = Data(#"{"cleanupPrompt":["tidy it up"],"bindings":"none"}"#.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: file)

        #expect(decoded.cleanupPrompt == Settings.defaults.cleanupPrompt)
        #expect(decoded.bindings == Settings.defaults.bindings)
    }

    @Test("an empty object is the defaults")
    func toleratesEmptyObject() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))

        #expect(decoded == Settings.defaults)
    }

    /// Ctrl+Space would never arrive: macOS gives it to the input source
    /// switcher.
    @Test("the default keys avoid the one macOS keeps for itself")
    func defaultKeysAreReachable() {
        let toggle = Settings.defaults.combination(for: .toggle)

        #expect(toggle == KeyCombination(key: "space", modifiers: [.control, .option]))
        #expect(Settings.defaults.bindings.isValid)

        let everyActionBound = HotkeyAction.allCases.allSatisfy {
            Settings.defaults.combination(for: $0) != nil
        }
        #expect(everyActionBound)
    }
}

@Suite("Settings service")
struct SettingsServiceTests {

    @Test("the first run gets the defaults and writes nothing")
    func startsFromDefaults() async {
        let storage = InMemorySettingsStorage()
        let service = SettingsService(storage: storage)

        #expect(await service.settings == Settings.defaults)
        #expect(await service.loadFailure == nil)
        #expect(storage.stored == nil)
    }

    @Test("a change is kept and written back")
    func savesChanges() async throws {
        let storage = InMemorySettingsStorage()
        let service = SettingsService(storage: storage)

        try await service.update { $0.language = "tr-TR" }

        #expect(await service.settings.language == "tr-TR")
        let written = try #require(storage.stored)
        let decoded = try JSONDecoder().decode(Settings.self, from: written)
        #expect(decoded.language == "tr-TR")
    }

    @Test("a change that changes nothing does not write")
    func skipsPointlessWrites() async throws {
        let storage = InMemorySettingsStorage()
        let service = SettingsService(storage: storage)

        try await service.update { $0.cleanupEnabled = Settings.defaults.cleanupEnabled }

        #expect(storage.stored == nil)
    }

    /// The file is left exactly where it is. A user whose settings will not
    /// parse gets a working application and a line telling them so; silently
    /// overwriting their file with defaults is not recoverable.
    @Test("an unreadable file falls back to defaults and says so, without overwriting it")
    func keepsUnreadableFile() async {
        let broken = Data("{ this is not json".utf8)
        let storage = InMemorySettingsStorage(initial: broken)

        let service = SettingsService(storage: storage)

        #expect(await service.settings == Settings.defaults)
        #expect(await service.loadFailure != nil)
        #expect(storage.stored == broken)
    }

    @Test("a storage that cannot be read at all is survivable")
    func survivesUnreadableStorage() async {
        struct Nope: Error {}
        let service = SettingsService(storage: InMemorySettingsStorage(loadFailure: Nope()))

        #expect(await service.settings == Settings.defaults)
        #expect(await service.loadFailure != nil)
    }

    /// The file that would not load is still the user's, and may be one typo
    /// from working. Defaults plus one change written over it would destroy it.
    @Test("after a failed load a change is kept in memory and the file is not written over")
    func keepsUnreadableFileThroughChanges() async {
        let broken = Data("{ this is not json".utf8)
        let storage = InMemorySettingsStorage(initial: broken)
        let service = SettingsService(storage: storage)

        await #expect(throws: SettingsServiceError.self) {
            try await service.update { $0.language = "de-DE" }
        }

        #expect(await service.settings.language == "de-DE")
        #expect(storage.stored == broken)
        #expect(await service.loadFailure != nil)
    }

    @Test("resetting after a failed load starts a new file, and changes are saved again")
    func resetEndsTheReadOnlySpell() async throws {
        let storage = InMemorySettingsStorage(initial: Data("{ this is not json".utf8))
        let service = SettingsService(storage: storage)

        try await service.reset()
        try await service.update { $0.language = "de-DE" }

        #expect(await service.loadFailure == nil)
        let written = try #require(storage.stored)
        let decoded = try JSONDecoder().decode(Settings.self, from: written)
        #expect(decoded.language == "de-DE")
    }

    /// The window shows what the user just chose rather than silently reverting,
    /// and the failure is theirs to see.
    @Test("a failed write throws but keeps the change in memory")
    func keepsChangeWhenWriteFails() async {
        struct DiskFull: Error {}
        let service = SettingsService(
            storage: InMemorySettingsStorage(saveFailure: DiskFull()))

        await #expect(throws: DiskFull.self) {
            try await service.update { $0.language = "de-DE" }
        }
        #expect(await service.settings.language == "de-DE")
    }
}
