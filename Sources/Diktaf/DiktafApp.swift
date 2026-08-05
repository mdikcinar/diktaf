import AppKit
import DiktafCore
import SwiftUI

@main
struct DiktafApp: App {
    /// The model belongs to the delegate rather than to a `@State` here, and this
    /// is not a matter of taste. Reading a `@State` from an `App`'s `init` hands
    /// back an instance SwiftUI then throws away, so the wiring done to it —
    /// registering the global keys — was done to an object that was deallocated a
    /// moment later. The keys fired, the handler ran, and its `weak self` was nil:
    /// a dictation key that did nothing at all, with nothing logged to say why.
    ///
    /// A delegate also gives the one moment worth doing this at, which is after
    /// the application has finished launching.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.menuBarSymbol)
                .accessibilityLabel(delegate.model.menuBarDescription)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow(model: delegate.model)
                .frame(width: 640, height: 470)
        }

        Window("Agent", id: "agent") {
            AgentWindow(model: delegate.model)
                .frame(minWidth: 460, minHeight: 320)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let overlay = OverlayController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await model.start()
            overlay.follow(model)
        }
    }
}

extension AppModel {
    /// The menu bar icon, which is the whole of Diktaf's presence on screen and
    /// therefore the only place a state can be shown from.
    var menuBarSymbol: String {
        switch state {
        case .idle:
            missingPermissions.isEmpty ? "mic" : "mic.badge.xmark"
        case .recording:
            "mic.fill"
        case .settling, .refining:
            "waveform"
        case .delivering:
            "text.insert"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var menuBarDescription: String {
        switch state {
        case .idle: "Diktaf, idle"
        case .recording: "Diktaf, recording"
        case .settling: "Diktaf, finishing the transcript"
        case .refining: "Diktaf, cleaning up"
        case .delivering: "Diktaf, pasting"
        case .failed(let message): "Diktaf: \(message)"
        }
    }
}
