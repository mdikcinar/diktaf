import DiktafCore
import SwiftUI

/// The conversation, for the dictations that were questions rather than text.
///
/// Replies are shown here and never pasted: a dictation aimed at the agent was
/// not aimed at the document, and quietly typing an answer into whatever had the
/// keyboard is not a thing to do to somebody.
struct AgentWindow: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.agentTurns.isEmpty {
                ContentUnavailableView {
                    Label("Henüz bir şey sorulmadı", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    if let key = model.settings.combination(for: .agent) {
                        Text("\(key.displayName) tuşuna basın, ne istediğinizi söyleyin, yeniden basın.")
                    } else {
                        Text("Ayarlar → Kısayollar'dan Agent için bir tuş atayın.")
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(model.agentTurns) { turn in
                            TurnView(turn: turn)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack {
                if model.agentIsThinking {
                    ProgressView().controlSize(.small)
                    Text("Düşünüyor…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Yeni konuşma başlat", action: model.clearConversation)
                    .disabled(model.agentTurns.isEmpty || model.agentIsThinking)
            }
            .padding(10)
        }
    }
}

private struct TurnView: View {
    let turn: AgentTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.prompt)
                .font(.headline)
                .textSelection(.enabled)

            switch turn.outcome {
            case .answered(let reply):
                Text(reply)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Kopyala", systemImage: "doc.on.doc") {
                    PasteboardWriter.write(reply)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A copy button needs the clipboard, and reaching for the adapter from a view
/// is the one place a shortcut here is honest: nothing about it is domain logic.
enum PasteboardWriter {
    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
