import DiktafCore
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)

        if let notice = model.notice {
            Button("⚠ \(notice)") { model.dismissNotice() }
        }

        Divider()

        Button(model.state.isBusy ? "Stop and transcribe" : "Start dictating") {
            model.toggle()
        }
        .keyboardShortcut("d")

        if model.state.isBusy {
            Button("Throw it away", action: model.cancel)
        }

        if model.settings.agentEnabled {
            Button("Ask the agent") { model.askAgent() }
                .disabled(model.state.isBusy || !model.agentAvailable)
            Button("Show the conversation") { openWindow(id: "agent") }
        }

        Divider()

        // Not a warning tucked away in a settings tab: without accessibility the
        // paste silently goes nowhere, so it belongs where the user is already
        // looking when nothing happened.
        ForEach(model.missingPermissions, id: \.self) { kind in
            Button("Allow \(kind.label)…") {
                Task { await model.request(kind) }
            }
        }

        if model.languageState == .notInstalled {
            Button("Download the speech model…") { openSettings() }
        }

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Diktaf") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension AppModel {
    var statusLine: String {
        switch state {
        case .idle:
            if let key = settings.combination(for: .toggle) {
                "Ready — press \(key.displayName)"
            } else {
                "Ready"
            }
        case .recording(let text, let destination):
            if text.isEmpty {
                destination == .agent ? "Listening (for the agent)…" : "Listening…"
            } else {
                String(text.suffix(48))
            }
        case .settling: "Finishing…"
        case .refining: "Cleaning up…"
        case .delivering: "Pasting…"
        case .failed(let message): message
        }
    }
}

extension PermissionKind {
    var label: String {
        switch self {
        case .microphone: "the microphone"
        case .speechRecognition: "speech recognition"
        case .keyboardControl: "Diktaf to paste"
        }
    }
}
