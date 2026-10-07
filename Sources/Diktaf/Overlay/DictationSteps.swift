import DiktafCore
import DiktafOllama
import Foundation

/// One line of the indicator once the user has stopped talking.
struct DictationStep: Identifiable, Equatable {
    enum Status: Equatable { case done, active, waiting, skipped, fellBack }

    let id: String
    var status: Status
    var title: String
    var trailing: String?
    var details: [String] = []
    var quote: String?
    var warning: String?
}

/// The words the indicator uses, worked out from the session's progress, the
/// settings, and what the refiner reported. Kept out of the views so that the
/// views only lay things out.
extension AppModel {
    // MARK: Listening

    var listeningFor: DictationDestination {
        if case .recording(_, let destination) = state { return destination }
        return progress?.destination ?? .insertion
    }

    /// "Whisper · Türkçe": which recogniser, in which language.
    var recogniserLabel: String {
        let engine = settings.engine == .whisper ? "Whisper" : "macOS"
        guard let language = settings.language else {
            return settings.engine == .whisper
                ? "\(engine) · dil otomatik"
                : "\(engine) · \(Self.languageName(Locale.current.identifier))"
        }
        return "\(engine) · \(Self.languageName(language))"
    }

    var whisperIsLoading: Bool {
        settings.engine == .whisper && whisperLoadState != .loaded
    }

    /// A microphone that is open and hearing nothing looks exactly like one
    /// that is listening to somebody who has not started yet — until it has
    /// gone on for long enough that it cannot be the second.
    var listeningWarning: String? {
        guard state.isRecording, hearsNothing else { return nil }
        return "Ses gelmiyor — mikrofon sessiz ya da yanlış giriş seçili olabilir."
    }

    /// How long until the quiet ends the dictation, once it has lasted long
    /// enough not to be the gap between two words.
    func silenceRemaining(at now: Date) -> TimeInterval? {
        guard settings.silenceStopEnabled, state.isRecording, let since = silenceSince else {
            return nil
        }
        let quiet = now.timeIntervalSince(since)
        guard quiet >= 0.6 else { return nil }
        return max(0, silenceStopDelay - quiet)
    }

    var listeningHint: String? {
        let finish = settings.combination(for: listeningFor == .agent ? .agent : .toggle)
        let cancel = settings.combination(for: .cancel)
        let parts = [finish.map { "\($0.displayName) bitir" }, cancel.map { "\($0.displayName) iptal" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: After the recording

    func steps(at now: Date) -> [DictationStep] {
        guard let progress else {
            return [DictationStep(id: "transcript", status: .active, title: "Metne çevriliyor")]
        }
        var steps: [DictationStep] = []

        if let ended = progress.recordingEndedAt {
            steps.append(DictationStep(
                id: "recording", status: .done, title: "Kayıt alındı",
                trailing: Self.seconds(ended.timeIntervalSince(progress.startedAt))))
        }

        steps.append(transcriptStep(progress, now: now))

        switch progress.destination {
        case .agent:
            steps.append(DictationStep(
                id: "agent", status: .waiting, title: "Agent'a sorulacak",
                details: ["Temizlenmeden, olduğu gibi gider."]))
        case .insertion:
            steps.append(cleanupStep(progress, now: now))
            steps.append(deliveryStep(progress))
        }
        return steps
    }

    private func transcriptStep(_ progress: DictationProgress, now: Date) -> DictationStep {
        if let ready = progress.transcriptReadyAt {
            let words = Self.wordCount(progress.rawTranscript ?? "")
            let took = progress.recordingEndedAt.map { ready.timeIntervalSince($0) } ?? 0
            return DictationStep(
                id: "transcript", status: .done, title: "Metne çevrildi",
                trailing: "\(words) kelime · \(Self.seconds(took))")
        }
        let since = progress.recordingEndedAt.map { now.timeIntervalSince($0) } ?? 0
        let how = settings.engine == .whisper
            ? "Whisper kaydın tamamını tek seferde okuyor."
            : "macOS son kelimeleri kesinleştiriyor."
        return DictationStep(
            id: "transcript", status: .active, title: "Metne çevriliyor",
            trailing: Self.seconds(since), details: [how])
    }

    private func cleanupStep(_ progress: DictationProgress, now: Date) -> DictationStep {
        guard let cleanup = progress.cleanup else {
            guard settings.cleanupEnabled else {
                return DictationStep(id: "cleanup", status: .skipped, title: "Temizleme kapalı")
            }
            return DictationStep(
                id: "cleanup", status: .waiting, title: "Temizlenecek",
                details: [plannedCleanupLabel])
        }

        switch cleanup.outcome {
        case .running:
            let elapsed = now.timeIntervalSince(cleanup.startedAt)
            return DictationStep(
                id: "cleanup", status: .active, title: "Temizleniyor",
                trailing: "\(Self.seconds(elapsed, unit: false)) / \(cleanup.deadlineSeconds) sn",
                details: [cleanupLabel],
                quote: progress.rawTranscript.map { "“\($0)”" },
                warning: cleanupChoice?.fallbackReason.map { "\($0) — Claude devraldı." })
        case .cleaned(let text, let finished):
            let before = Self.wordCount(progress.rawTranscript ?? "")
            let after = Self.wordCount(text)
            return DictationStep(
                id: "cleanup", status: .done, title: "Temizlendi",
                trailing: Self.seconds(finished.timeIntervalSince(cleanup.startedAt)),
                details: [before == after
                    ? "\(cleanupLabel) · \(after) kelime"
                    : "\(cleanupLabel) · \(before) → \(after) kelime"])
        case .fellBack(let reason, let finished):
            return DictationStep(
                id: "cleanup", status: .fellBack, title: "Temizlenemedi — ham metin kullanılıyor",
                trailing: Self.seconds(finished.timeIntervalSince(cleanup.startedAt)),
                warning: reason)
        case .skipped(let reason):
            let why = switch reason {
            case .disabled: "Ayarlarda kapalı."
            case .noPrompt: "Talimat boş."
            case .noRefiner: "Temizleyici yok."
            }
            return DictationStep(
                id: "cleanup", status: .skipped, title: "Temizleme atlandı", details: [why])
        }
    }

    private func deliveryStep(_ progress: DictationProgress) -> DictationStep {
        let mode = progress.delivery ?? settings.delivery
        let target = deliveryTarget.map { "→ \($0)" }
        let active = state == .delivering
        let title = switch mode {
        case .paste: active ? "Yapıştırılıyor" : "Yapıştırılacak"
        case .type: active ? "Yazılıyor" : "Yazılacak"
        case .clipboardOnly: active ? "Panoya kopyalanıyor" : "Panoya kopyalanacak"
        }
        return DictationStep(
            id: "delivery", status: active ? .active : .waiting, title: title,
            trailing: mode == .clipboardOnly ? nil : target)
    }

    /// Who is cleaning up right now — the refiner's own report, since Claude
    /// may be standing in for Ollama.
    private var cleanupLabel: String {
        guard let choice = cleanupChoice else { return plannedCleanupLabel }
        return Self.label(engine: choice.engine, model: choice.model)
    }

    private var plannedCleanupLabel: String {
        switch settings.cleanupEngine {
        case .ollama: Self.label(engine: .ollama, model: chosenOllamaModel)
        case .claude: Self.label(engine: .claude, model: settings.cleanupModel ?? "claude")
        }
    }

    private static func label(engine: CleanupEngine, model: String) -> String {
        switch engine {
        case .ollama: "\(model) (Ollama)"
        case .claude: model == "claude" ? "Claude" : "Claude \(model)"
        }
    }

    // MARK: How it went

    func headline(for outcome: DictationOutcome) -> String {
        switch outcome {
        case .delivered(let progress, let target):
            let arrow = target.map { " → \($0)" } ?? ""
            return switch progress.delivery ?? settings.delivery {
            case .paste: "Yapıştırıldı\(arrow)"
            case .type: "Yazıldı\(arrow)"
            case .clipboardOnly: "Panoya kopyalandı"
            }
        case .askedAgent: return "Agent'a soruldu"
        case .nothingHeard: return "Bir şey duyulmadı"
        case .cancelled: return "Kayıt atıldı"
        case .failed(let message): return message
        }
    }

    func detail(for outcome: DictationOutcome) -> String? {
        switch outcome {
        case .delivered(let progress, _):
            var parts: [String] = []
            if let cleanup = progress.cleanup, case .cleaned(let text, let finished) = cleanup.outcome {
                parts.append("\(Self.wordCount(text)) kelime")
                parts.append("temizleme \(Self.seconds(finished.timeIntervalSince(cleanup.startedAt)))")
            } else {
                parts.append("\(Self.wordCount(progress.rawTranscript ?? "")) kelime, ham metin")
            }
            if let delivered = progress.deliveredAt {
                parts.append("toplam \(Self.seconds(delivered.timeIntervalSince(progress.startedAt)))")
            }
            return parts.joined(separator: " · ")
        case .askedAgent:
            return "Yanıt Agent penceresinde görünecek."
        case .nothingHeard:
            return "Kayıt sessizdi; hiçbir şey yapıştırılmadı."
        case .cancelled, .failed:
            return nil
        }
    }

    // MARK: Formatting

    static func seconds(_ value: TimeInterval, unit: Bool = true) -> String {
        let number = max(0, value).formatted(
            .number.precision(.fractionLength(1)).locale(Locale(identifier: "tr_TR")))
        return unit ? "\(number) sn" : number
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// "Türkçe", whatever language the system itself is set to.
    static func languageName(_ identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale(identifier: "tr").localizedString(forLanguageCode: code)?
            .capitalized(with: Locale(identifier: "tr")) ?? identifier
    }
}
