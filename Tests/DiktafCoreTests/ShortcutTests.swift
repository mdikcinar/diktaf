import Foundation
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

@Suite("Mouse buttons as shortcuts")
struct MouseButtonTests {

    @Test("a spare button is a combination like any other")
    func makesAMouseCombination() {
        let combination = KeyCombination.mouseButton(4, modifiers: [.control])

        #expect(combination.mouseButton == 4)
        #expect(combination.isMouseButton)
        #expect(combination.displayName == "Ctrl+Mouse 4")
    }

    /// Binding the left or right button would leave the user unable to click
    /// anything, so those numbers are not mouse buttons as far as this is
    /// concerned.
    @Test("the left and right buttons are not offered", arguments: [1, 2])
    func refusesTheClickingButtons(_ number: Int) {
        #expect(KeyCombination.mouseButton(number).mouseButton == nil)
        #expect(!KeyCombination.mouseButton(number).isMouseButton)
    }

    @Test("the middle one is called what people call it")
    func namesTheMiddleButton() {
        #expect(KeyCombination.mouseButton(3).displayName == "Middle Click")
        #expect(KeyCombination(parsing: "Middle Click") == KeyCombination.mouseButton(3))
        #expect(KeyCombination(parsing: "mouse3") == KeyCombination.mouseButton(3))
    }

    /// The names have spaces in them, so the round trip is where this breaks if
    /// the parser is careless.
    @Test("printing one and reading it back gives the same button", arguments: [
        KeyCombination.mouseButton(3),
        KeyCombination.mouseButton(4, modifiers: [.control, .option]),
        KeyCombination.mouseButton(9, modifiers: [.command]),
    ])
    func roundTripsThroughText(_ original: KeyCombination) {
        #expect(KeyCombination(parsing: original.displayName) == original)
    }

    @Test("a key is not a mouse button")
    func distinguishesKeys() {
        #expect(KeyCombination(key: "space", modifiers: []).mouseButton == nil)
        #expect(KeyCombination(key: "mouse", modifiers: []).mouseButton == nil)
        #expect(KeyCombination(key: "mousex", modifiers: []).mouseButton == nil)
    }

    /// There is no application that needs the fourth mouse button the way every
    /// application needs the letter D, so a bare one is fine.
    @Test("a bare mouse button is not the mistake a bare key would be")
    func allowsBareMouseButtons() {
        let mouse = [HotkeyBinding(action: .toggle, combination: .mouseButton(4))]
        let key = [HotkeyBinding(action: .toggle,
                                 combination: KeyCombination(key: "d", modifiers: []))]

        #expect(mouse.problems().isEmpty)
        #expect(!key.problems().isEmpty)
    }

    @Test("two actions on one button is still caught")
    func catchesDuplicateButtons() {
        let bindings = [
            HotkeyBinding(action: .toggle, combination: .mouseButton(4)),
            HotkeyBinding(action: .cancel, combination: .mouseButton(4)),
        ]

        #expect(bindings.problems().count == 1)
    }

    @Test("it survives being written to the settings file")
    func roundTripsThroughJSON() throws {
        var settings = Settings.defaults
        settings.bindings = [HotkeyBinding(action: .toggle, combination: .mouseButton(5))]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.combination(for: .toggle)?.mouseButton == 5)
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
