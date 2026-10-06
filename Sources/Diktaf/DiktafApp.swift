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
            MenuBarLabel(model: delegate.model)
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

/// The icon, and the one view that is always there — which makes it the place
/// the agent window is opened from when a reply is on its way, since opening a
/// window takes a view's environment.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel(model.menuBarDescription)
            .onChange(of: model.agentWindowRequests) {
                openWindow(id: "agent")
                NSApplication.shared.activate()
            }
    }
}

extension AppModel {
    /// The menu bar icon, which is the whole of Diktaf's presence on screen and
    /// therefore the only place a state can be shown from.
    var menuBarSymbol: String {
        if isStarting { return "mic.fill" }
        return switch state {
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
        case .idle: "Diktaf, hazır"
        case .recording: "Diktaf, dinliyor"
        case .settling: "Diktaf, metne çeviriyor"
        case .refining: "Diktaf, temizliyor"
        case .delivering: "Diktaf, yapıştırıyor"
        case .failed(let message): "Diktaf: \(message)"
        }
    }
}
