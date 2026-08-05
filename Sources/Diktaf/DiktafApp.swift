import DiktafCore
import SwiftUI

@main
struct DiktafApp: App {
    @State private var model = AppModel()

    /// Held here rather than in a scene: the indicator is an AppKit panel because
    /// no SwiftUI window can be shown without disturbing the keyboard, and the
    /// panel has to outlive any one view's lifetime.
    @State private var overlay = OverlayController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.menuBarDescription)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow(model: model)
                .frame(width: 620, height: 460)
        }

        Window("Agent", id: "agent") {
            AgentWindow(model: model)
                .frame(minWidth: 460, minHeight: 320)
        }
        .defaultLaunchBehavior(.suppressed)
    }

    init() {
        let model = self.model
        let overlay = self.overlay
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
