import DiktafCore
import DiktafMac
import DiktafWhisper
import Foundation

/// The `Transcriber` the session holds, standing in front of the two real ones.
///
/// `DictationSession` is handed its transcriber once and keeps it for the life of
/// the application, which is right — a session that could have its recogniser
/// swapped from under it mid-sentence is a session with a state nobody can reason
/// about. But the engine is a setting, and a setting that only takes effect after
/// a restart is a setting that looks broken.
///
/// So this is where the two facts meet. The session sees one transcriber that
/// never changes; the choice is read at `start()`, which is the only moment where
/// changing it is free. Switch the engine mid-dictation and the dictation in
/// progress finishes on the recogniser it began on, because `active` is captured
/// rather than looked up again.
///
/// It lives in the app target rather than in Core because it is composition —
/// this is the object that knows both adapters exist.
actor EngineSwitchingTranscriber: Transcriber {
    private let system: SystemTranscriber
    private let whisper: WhisperTranscriber

    private var engine: TranscriptionEngine

    /// The one a dictation is actually running on, or nil between dictations.
    /// `stop()` and `cancel()` must reach the recogniser that was started, not
    /// the one that is currently chosen — and must still reach it while it is
    /// settling, which is why `stop()` clears this only once the recogniser has
    /// finished.
    private var active: TranscriptionEngine?

    /// The recogniser's stop, while it is settling. `start()` waits for it, so
    /// the last pass of one dictation cannot land in the next.
    private var stopping: Task<Void, any Error>?

    /// Counted up by every `start()`, so that a stop returning after the next
    /// dictation has begun does not clear that one's `active`.
    private var dictation = 0

    init(
        engine: TranscriptionEngine,
        system: SystemTranscriber,
        whisper: WhisperTranscriber
    ) {
        self.engine = engine
        self.system = system
        self.whisper = whisper
    }

    /// Changes which recogniser the *next* dictation uses.
    func use(engine newEngine: TranscriptionEngine) {
        engine = newEngine
    }

    /// The language, told to both.
    ///
    /// Both rather than only the one in use, so that switching engines does not
    /// also silently reset the language: the two keep the setting independently
    /// and there is no moment afterwards at which anybody would think to reapply
    /// it.
    func use(locale: Locale?) async {
        await system.use(locale: locale)
        await whisper.use(locale: locale)
    }

    func use(whisperModel model: WhisperModel) async {
        await whisper.use(model: model)
    }

    /// Gets Whisper into memory before anybody presses a key.
    ///
    /// Not part of `Transcriber`, and it should not be: the port describes one
    /// dictation, and the system recogniser has nothing to preload. This is the
    /// app asking a specific engine to get ready.
    func prepareWhisper() async throws {
        try await whisper.prepare()
    }

    /// Whether Whisper's model is in memory, so the indicator can say that the
    /// recording is running while the model is still loading. Outside
    /// `Transcriber` for the same reason as `prepareWhisper()`.
    func whisperLoadState() async -> WhisperTranscriber.LoadState {
        await whisper.loadState
    }

    /// How loud the microphone is for the dictation in progress, from 0 to 1,
    /// and 0 between dictations.
    func inputLevel() async -> Float {
        switch active {
        case .whisper: await whisper.inputLevel()
        case .system: await system.inputLevel()
        case nil: 0
        }
    }

    /// The last buffer's RMS in dBFS, and −∞ between dictations.
    func inputDecibels() async -> Float {
        switch active {
        case .whisper: await whisper.inputDecibels()
        case .system: await system.inputDecibels()
        case nil: -.infinity
        }
    }

    /// How much the dictation in progress has recorded, and 0 between
    /// dictations.
    func recordedSeconds() async -> Double {
        switch active {
        case .whisper: await whisper.recordedSeconds()
        case .system: await system.recordedSeconds()
        case nil: 0
        }
    }

    private func recogniser(for engine: TranscriptionEngine) -> any Transcriber {
        engine == .whisper ? whisper : system
    }

    func start() async throws -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        await finishPrevious()
        dictation += 1
        let ours = dictation
        let chosen = engine
        active = chosen
        do {
            return try await recogniser(for: chosen).start()
        } catch {
            // Cleared on the way out, or a failed start would leave `stop()`
            // talking to a recogniser that never began.
            if dictation == ours { active = nil }
            throw error
        }
    }

    /// A stop still settling is waited for; a dictation started and never
    /// stopped is cancelled, because once the next one begins nothing could
    /// reach it again.
    private func finishPrevious() async {
        if let stopping {
            _ = await stopping.result
            if self.stopping == stopping { self.stopping = nil }
        } else if let active {
            self.active = nil
            await recogniser(for: active).cancel()
        }
    }

    func stop() async throws {
        if let stopping { return try await stopping.value }
        guard let active else { return }
        let ours = dictation
        let recogniser = recogniser(for: active)
        let stopping = Task { try await recogniser.stop() }
        self.stopping = stopping

        let outcome = await stopping.result
        // Cancelled while it settled, or a later start has already taken over:
        // either way what this stop found out is nobody's any more.
        guard self.stopping == stopping else { return }
        self.stopping = nil
        if dictation == ours { self.active = nil }
        try outcome.get()
    }

    func cancel() async {
        guard let active else { return }
        self.active = nil
        // The recogniser abandons its own stop, so the next start has nothing
        // to wait for.
        stopping = nil
        await recogniser(for: active).cancel()
    }
}
