import Testing
@testable import DiktafCore

@Suite("Key combinations")
struct KeyCombinationTests {

    @Test("the three vocabularies all parse to the same key", arguments: [
        "Ctrl+Alt+Space",
        "ctrl+alt+space",
        "Control+Option+Space",
        "CONTROL-OPTION-SPACE",
        " Ctrl + Alt + Space ",
    ])
    func parsesEquivalentSpellings(_ text: String) {
        #expect(KeyCombination(parsing: text)
                == KeyCombination(key: "space", modifiers: [.control, .option]))
    }

    @Test("cmd, command, meta and super are one modifier", arguments: [
        "Cmd+D", "Command+D", "Meta+D", "Super+D",
    ])
    func acceptsCommandSpellings(_ text: String) {
        #expect(KeyCombination(parsing: text)
                == KeyCombination(key: "d", modifiers: [.command]))
    }

    @Test("a canonical spelling comes back out")
    func rendersCanonically() {
        let combination = KeyCombination(parsing: "super-shift-option-control-f13")

        #expect(combination?.displayName == "Ctrl+Alt+Shift+Cmd+F13")
    }

    @Test("parsing what it prints gives the same key back", arguments: [
        KeyCombination(key: "space", modifiers: [.control, .option]),
        KeyCombination(key: "d", modifiers: [.command, .shift]),
        KeyCombination(key: "f13", modifiers: []),
        KeyCombination(key: "a", modifiers: [.control, .option, .shift, .command]),
    ])
    func roundTrips(_ original: KeyCombination) {
        #expect(KeyCombination(parsing: original.displayName) == original)
    }

    @Test("junk is refused rather than half-read", arguments: [
        "", "   ", "+", "+++", "Ctrl+", "Ctrl", "Ctrl+Alt", "Cmd+Shift",
        "Ctrl+A+B", "Space+Space",
    ])
    func refusesJunk(_ text: String) {
        #expect(KeyCombination(parsing: text) == nil)
    }

    @Test("a repeated modifier says nothing new and is accepted")
    func toleratesRepeatedModifiers() {
        #expect(KeyCombination(parsing: "Ctrl+Ctrl+Space")
                == KeyCombination(key: "space", modifiers: [.control]))
    }

    @Test("a bare key is a key, with no modifiers")
    func acceptsBareKey() {
        #expect(KeyCombination(parsing: "f13")
                == KeyCombination(key: "f13", modifiers: []))
    }
}

@Suite("Binding validation")
struct BindingValidationTests {

    /// The platform's own answer is unhelpful — it takes the first registration
    /// and refuses the second, and what the user sees is a key doing the wrong
    /// thing.
    @Test("two actions on one key is caught before the system sees it")
    func catchesDuplicates() {
        let shared = KeyCombination(key: "space", modifiers: [.control, .option])
        let bindings = [
            HotkeyBinding(action: .toggle, combination: shared),
            HotkeyBinding(action: .cancel, combination: shared),
        ]

        let problems = bindings.problems()

        #expect(problems.count == 1)
        #expect(problems.first == .duplicate(shared, [.toggle, .cancel]))
        #expect(!bindings.isValid)
    }

    @Test("a key with no modifiers would swallow that key everywhere")
    func catchesUnmodifiedKeys() {
        let bare = KeyCombination(key: "d", modifiers: [])
        let bindings = [HotkeyBinding(action: .toggle, combination: bare)]

        #expect(bindings.problems() == [.noModifiers(.toggle, bare)])
    }

    @Test("the defaults have nothing wrong with them")
    func defaultsAreValid() {
        #expect(Settings.defaultBindings.problems().isEmpty)
    }

    @Test("the same action twice on the same key is still one problem")
    func reportsEachDuplicateOnce() {
        let shared = KeyCombination(key: "space", modifiers: [.control])
        let bindings = [
            HotkeyBinding(action: .toggle, combination: shared),
            HotkeyBinding(action: .cancel, combination: shared),
            HotkeyBinding(action: .agent, combination: shared),
        ]

        #expect(bindings.problems().count == 1)
    }
}
