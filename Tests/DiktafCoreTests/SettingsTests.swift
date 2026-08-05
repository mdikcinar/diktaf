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
        original.rules.extraInstruction = "keep it short"

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
        #expect(decoded.rules == Settings.defaults.rules)
        #expect(decoded.bindings == Settings.defaults.bindings)
        #expect(decoded.refinerTimeoutSeconds == Settings.defaults.refinerTimeoutSeconds)
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
