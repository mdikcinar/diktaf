import Foundation

/// What the system has and has not allowed.
///
/// Asked before acting rather than after, because the interesting failure is
/// the silent one: told to press a key it has not been allowed to, macOS
/// reports that it did. Nothing fails, nothing is logged, and the text arrives
/// nowhere. A permission that is merely undetermined is worth a prompt; one
/// that is denied is worth saying so in the menu.
public protocol PermissionAuthority: Sendable {
    func state(of kind: PermissionKind) async -> PermissionState

    /// Puts the system's own prompt up and answers with the state as it stands
    /// afterwards. Never waits for the user to visit the settings pane.
    @discardableResult
    func request(_ kind: PermissionKind) async -> PermissionState

    /// Opens the pane that grants it, for the case where asking is no longer
    /// possible because the answer was already no.
    func openSettings(for kind: PermissionKind)
}

public enum PermissionKind: String, Sendable, Codable, CaseIterable {
    /// Recording anything at all.
    case microphone
    /// Turning the recording into text on this machine.
    case speechRecognition
    /// Pressing a key on the user's behalf, which is what pasting is.
    case keyboardControl
}

public enum PermissionState: String, Sendable, Equatable {
    case granted
    case denied
    /// Never asked. The only state where prompting achieves anything.
    case undetermined
}
