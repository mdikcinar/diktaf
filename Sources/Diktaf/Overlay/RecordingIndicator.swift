import DiktafCore
import DiktafWhisper
import SwiftUI

/// What the panel draws: while listening, whether it can hear you; after that,
/// each step behind the text and how long it is taking; at the end, how it went.
///
/// The live text and the meter are the point of the first half. A red dot tells
/// the user that Diktaf thinks it is recording, which is not the question they
/// have — the question is whether it can hear them. The steps are the point of
/// the second: a spinner that says "cleaning up" for four seconds is
/// indistinguishable from one that has hung.
struct RecordingIndicator: View {
    let model: AppModel

    static let width: CGFloat = 380

    var body: some View {
        Group {
            if let outcome = model.outcome, !model.state.isBusy, !model.isStarting {
                OutcomeView(model: model, outcome: outcome)
            } else if model.isStarting || model.state.isRecording {
                ListeningView(model: model)
            } else {
                StepsView(model: model)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .animation(.snappy(duration: 0.25), value: model.state)
        .animation(.snappy(duration: 0.25), value: model.outcome)
    }
}

// MARK: - Listening

private struct ListeningView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isStarting {
                    ProgressView().controlSize(.small)
                    Text("Mikrofon açılıyor…").font(.headline)
                } else {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text(model.listeningFor == .agent ? "Dinliyorum — Agent'a sorulacak" : "Dinliyorum")
                        .font(.headline)
                }
                Spacer(minLength: 0)
                if let started = model.progress?.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(started)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                LevelMeter(levels: model.inputLevels)
                    .frame(height: 22)
                Text(model.recogniserLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let warning = model.listeningWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if case .recording(let text, _) = model.state, !text.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if model.settings.engine == .whisper {
                        Text("Önizleme — son hali durdurunca çıkar")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(text)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .truncationMode(.head)
                }
            } else if model.whisperIsLoading {
                Text("Whisper belleğe yükleniyor — bu arada ses kaydediliyor, hiçbir şey kaybolmaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                // The countdown takes the hint's place rather than a line of its
                // own, so the card does not grow and shrink at every pause.
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    if let remaining = model.silenceRemaining(at: context.date) {
                        Text("Sessizlik — \(AppModel.seconds(remaining)) sonra bitecek")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText(countsDown: true))
                    } else if let hint = model.listeningHint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                if !model.isStarting {
                    Button("Bitir", systemImage: "stop.fill") { model.toggle() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Kaydı bitir ve metne çevir")
                }
                CancelButton(model: model)
            }
            .controlSize(.small)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

/// The last couple of seconds of input, as bars. Drawn from the adapter's own
/// level rather than from the text, because silence and a dead microphone both
/// produce no text and only one of them is the user's doing.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        let padded = Array(repeating: Float(0), count: max(0, AppModel.meterLength - levels.count)) + levels
        HStack(alignment: .center, spacing: 2) {
            ForEach(padded.indices, id: \.self) { index in
                Capsule()
                    .fill(padded[index] > 0.04 ? Color.red.opacity(0.85) : Color.secondary.opacity(0.35))
                    .frame(width: 3, height: 3 + CGFloat(padded[index]) * 19)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityHidden(true)
    }
}

// MARK: - The steps behind the text

private struct StepsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.steps(at: context.date)) { step in
                        StepRow(step: step)
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                CancelButton(model: model)
            }
            .controlSize(.small)
        }
    }
}

/// Throws the dictation away from wherever it has got to, for somebody whose
/// hand is on the mouse rather than the keyboard.
private struct CancelButton: View {
    let model: AppModel

    var body: some View {
        Button("İptal", systemImage: "xmark") { model.cancel() }
            .buttonStyle(.bordered)
            .help(model.settings.combination(for: .cancel)
                .map { "Kaydı at (\($0.displayName))" } ?? "Kaydı at")
    }
}

private struct StepRow: View {
    let step: DictationStep

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker.frame(width: 16)
                Text(step.title)
                    .font(.system(size: 13, weight: step.status == .active ? .semibold : .regular))
                    .foregroundStyle(step.status == .waiting ? .secondary : .primary)
                Spacer(minLength: 8)
                if let trailing = step.trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            ForEach(step.details, id: \.self) { detail in
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            if let quote = step.quote {
                Text(quote)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
            }
            if let warning = step.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder private var marker: some View {
        switch step.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active:
            ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .fellBack:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - How it went

private struct OutcomeView: View {
    let model: AppModel
    let outcome: DictationOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                symbol
                Text(model.headline(for: outcome))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            if let detail = model.detail(for: outcome) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            if case .delivered = outcome, let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.dismissOutcome() }
        .help("Kapatmak için tıklayın")
    }

    @ViewBuilder private var symbol: some View {
        Group {
            switch outcome {
            case .delivered, .askedAgent:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .nothingHeard:
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
            case .cancelled:
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .frame(width: 16)
    }
}

extension DictationState {
    var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}
