import Foundation

/// What is wrong with a set of shortcuts, before the system is asked to
/// register it.
///
/// Checked here rather than left to the platform because the platform's answer
/// is unhelpful: asked to register two actions on one key, it takes the first
/// and refuses the second, and what the user sees is a key that does the wrong
/// thing. This is the settings window's job, and it is testable.
public enum BindingProblem: Sendable, Equatable {
    /// Two or more actions want the same combination.
    case duplicate(KeyCombination, [HotkeyAction])
    /// A combination with no modifiers at all, which would swallow the key
    /// everywhere — typing "d" would start a dictation.
    case noModifiers(HotkeyAction, KeyCombination)
}

extension Array where Element == HotkeyBinding {
    /// Everything wrong with these bindings, in a fixed order so that a test
    /// and a settings window see the same list.
    public func problems() -> [BindingProblem] {
        var problems: [BindingProblem] = []

        var byCombination: [KeyCombination: [HotkeyAction]] = [:]
        for binding in self {
            byCombination[binding.combination, default: []].append(binding.action)
        }
        for binding in self where byCombination[binding.combination]?.count ?? 0 > 1 {
            guard let actions = byCombination[binding.combination] else { continue }
            let problem = BindingProblem.duplicate(binding.combination, actions)
            if !problems.contains(problem) { problems.append(problem) }
        }

        // A mouse button is exempt. Binding a spare button with no modifier is
        // the normal way to use one, and it takes nothing away: there is no
        // application that needs the fourth button the way every application
        // needs the letter D.
        for binding in self
        where binding.combination.modifiers.isEmpty && !binding.combination.isMouseButton {
            problems.append(.noModifiers(binding.action, binding.combination))
        }

        return problems
    }

    public var isValid: Bool { problems().isEmpty }
}
