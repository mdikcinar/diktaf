import DiktafCore
import SwiftUI

/// What the panel draws: the state, and the words as they arrive.
///
/// The live text is the point. A dictation indicator that shows only a red dot
/// tells the user that Diktaf thinks it is recording, which is not the question
/// they have — the question is whether it can hear them.
struct RecordingIndicator: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            symbol
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .recording(let text, _) = model.state, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private var symbol: some View {
        Group {
            switch model.state {
            case .recording: Image(systemName: "mic.fill").symbolEffect(.pulse)
            case .settling, .refining: ProgressView().controlSize(.small)
            case .delivering: Image(systemName: "text.insert")
            case .failed: Image(systemName: "exclamationmark.triangle.fill")
            case .idle: Image(systemName: "mic")
            }
        }
    }

    private var tint: Color {
        switch model.state {
        case .recording: .red
        case .failed: .orange
        default: .secondary
        }
    }

    private var headline: String {
        switch model.state {
        case .recording(_, let destination):
            destination == .agent ? "Asking the agent" : "Dictating"
        case .settling: "Finishing"
        case .refining: "Cleaning up"
        case .delivering: "Pasting"
        case .failed(let message): message
        case .idle: "Ready"
        }
    }
}
