import DiktafCore
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)

        if let detail = model.statusDetail {
            Text(detail)
        }

        if let notice = model.notice {
            Button("⚠ \(notice)") { model.dismissNotice() }
        }

        Divider()

        Button(model.state.isRecording ? "Durdur ve metne çevir" : "Dikteye başla") {
            model.toggle()
        }
        .keyboardShortcut("d")

        if model.state.isBusy {
            Button("Kaydı at", action: model.cancel)
        }

        if model.settings.agentEnabled {
            Button("Agent'a sor") { model.askAgent() }
                .disabled(model.state.isBusy || !model.agentAvailable)
            Button(model.agentIsThinking ? "Agent penceresi (yanıtlıyor…)" : "Agent penceresi") {
                openWindow(id: "agent")
                NSApplication.shared.activate()
            }
        }

        Divider()

        // Not a warning tucked away in a settings tab: without accessibility the
        // paste silently goes nowhere, so it belongs where the user is already
        // looking when nothing happened.
        ForEach(model.missingPermissions, id: \.self) { kind in
            Button("\(kind.label) izni ver…") {
                Task { await model.request(kind) }
            }
        }

        if model.engineNeedsDownload {
            Button(model.settings.engine == .whisper
                   ? "Whisper modelini indir…" : "Konuşma modelini indir…") { showSettings() }
        }

        Button("Ayarlar…") { showSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Diktaf'tan çık") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension MenuBarContent {
    /// An accessory application's windows open behind whatever is in front
    /// unless it is brought forward first.
    fileprivate func showSettings() {
        openSettings()
        NSApplication.shared.activate()
    }
}

extension AppModel {
    var statusLine: String {
        if isStarting { return "Mikrofon açılıyor…" }
        switch state {
        case .idle:
            if let key = settings.combination(for: .toggle) {
                return "Hazır — \(key.displayName) ile başlat"
            }
            return "Hazır"
        case .recording(let text, let destination):
            if text.isEmpty {
                return destination == .agent ? "Dinliyorum (Agent için)…" : "Dinliyorum…"
            }
            return String(text.suffix(48))
        case .settling: return "Metne çevriliyor…"
        case .refining: return "Temizleniyor…"
        case .delivering: return "Yapıştırılıyor…"
        case .failed(let message): return message
        }
    }

    /// The second line: who is doing the work right now.
    var statusDetail: String? {
        switch state {
        case .recording: recogniserLabel
        case .refining: cleanupChoice.map {
            $0.engine == .ollama ? "\($0.model) (Ollama)" : "Claude"
        }
        case .idle:
            settings.cleanupEnabled
                ? "\(recogniserLabel) · temizleme: "
                  + (settings.cleanupEngine == .ollama ? chosenOllamaModel : "Claude")
                : "\(recogniserLabel) · temizleme kapalı"
        default: nil
        }
    }
}

extension PermissionKind {
    var label: String {
        switch self {
        case .microphone: "Mikrofon"
        case .speechRecognition: "Konuşma tanıma"
        case .keyboardControl: "Yapıştırma (Erişilebilirlik)"
        }
    }
}
