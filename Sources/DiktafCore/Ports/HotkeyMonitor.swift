import Foundation

/// The keys that reach Diktaf while another application has the keyboard.
///
/// Rebinding is the whole interface: the monitor is told the full set every
/// time rather than being asked to add and remove, because a half-applied set
/// is the failure mode worth designing out — a key that still fires after it
/// was changed is indistinguishable, to the user, from one that never worked.
public protocol HotkeyMonitor: Sendable {
    /// Registers exactly these bindings and forgets any earlier ones.
    ///
    /// The handler may be called on any thread. Combinations another
    /// application already holds cannot be taken, and which ones those were is
    /// what the return value reports — an empty array means all of them took.
    @discardableResult
    func rebind(
        _ bindings: [HotkeyBinding],
        onTrigger: @escaping @Sendable (HotkeyAction) -> Void
    ) -> [HotkeyBinding]

    /// Releases every key back to the system.
    func unbindAll()
}

/// What a key is for. The set is closed: a shortcut that does not do one of
/// these things is not a shortcut Diktaf has.
public enum HotkeyAction: String, Sendable, Codable, CaseIterable {
    /// Start recording, or stop and transcribe.
    case toggle
    /// Throw away what is being recorded.
    case cancel
    /// Record and put what was said to the agent rather than pasting it.
    case agent
}

public struct HotkeyBinding: Sendable, Equatable, Codable {
    public let action: HotkeyAction
    public let combination: KeyCombination

    public init(action: HotkeyAction, combination: KeyCombination) {
        self.action = action
        self.combination = combination
    }
}
