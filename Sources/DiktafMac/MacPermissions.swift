import AVFoundation
import AppKit
import ApplicationServices
import DiktafCore
import Speech

/// What macOS has and has not allowed.
public struct MacPermissions: PermissionAuthority {
    public init() {}

    public func state(of kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .undetermined
            case .denied, .restricted: .denied
            @unknown default: .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .granted
            case .notDetermined: .undetermined
            case .denied, .restricted: .denied
            @unknown default: .denied
            }
        case .keyboardControl:
            // Two states rather than three: there is no way to ask macOS whether
            // it has been asked. Reported as undetermined rather than denied so
            // that the interface offers the prompt, which is the only route to
            // the pane that grants it.
            AXIsProcessTrusted() ? .granted : .undetermined
        }
    }

    @discardableResult
    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .keyboardControl:
            promptForAccessibility()
        }
        return await state(of: kind)
    }

    public func openSettings(for kind: PermissionKind) {
        let pane = switch kind {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .keyboardControl: "Privacy_Accessibility"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Puts up the system's own accessibility dialogue and answers with the state
    /// as it stands, rather than waiting for the user to walk to the settings.
    ///
    /// The key is `kAXTrustedCheckOptionPrompt` written out, because the framework
    /// declares its own constant as a mutable C global that Swift 6 will not read
    /// from concurrent code. Spelling it is safe here for a reason worth knowing:
    /// bridging a Swift dictionary with `as CFDictionary` produces one whose keys
    /// are compared by value. Built by hand with no callbacks, a CFDictionary
    /// compares its keys by address instead — and then HIServices does not find
    /// this option, reads the type of the value it did not get, and crashes
    /// inside the check before it ever returns.
    private func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
