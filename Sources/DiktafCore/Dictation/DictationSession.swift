import Foundation

/// One dictation at a time, from the key press to the text arriving.
///
/// The whole flow lives here so that it can be read in one place and tested
/// without a microphone: every collaborator is a port, and the tests drive it
/// with fakes. Nothing else in the application may change the state — the
/// interface watches `events` and the hotkeys call `toggle` and `cancel`.
public actor DictationSession {
    private let transcriber: any Transcriber
    private let refiner: (any TextRefiner)?
    private let clipboard: any Clipboard
    private let keyboard: any KeyboardSender
    private let focus: any FocusGuard
    private let readSettings: @Sendable () async -> Settings

    /// Sleeping is injected so that the timeout can be tested in microseconds
    /// rather than by waiting out a real deadline.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Injected so the tests can pin the timestamps in `DictationProgress`
    /// rather than asserting around them.
    private let now: @Sendable () -> Date

    private var state: DictationState = .idle
    private var listeners: [UUID: AsyncStream<DictationEvent>.Continuation] = [:]

    /// Which dictation is the current one, bumped when one starts and when one
    /// is cancelled.
    ///
    /// Every await can come back to find the dictation it belonged to cancelled,
    /// or cancelled and replaced. Whatever was in flight holds the number it
    /// started with and gives up when that is no longer current — otherwise a
    /// cancelled dictation still pastes, or a stale one clobbers the next.
    private var generation = 0

    /// While `transcriber.start()` is under way. The state is still idle then,
    /// so without this a second press would start a second recording and a
    /// cancel would find nothing to cancel.
    private var isStarting = false
    private var cancelRequested = false

    /// The last `transcriber.cancel()`, which a new recording waits for so
    /// that stopping one and starting the next never overlap in the adapter.
    private var cancelling: Task<Void, Never>?

    /// The task draining the transcriber, and the transcript it is building.
    private var consumer: Task<Void, Never>?
    private var settled = ""
    private var volatile = ""

    /// Whether the transcriber's stream is still running.
    ///
    /// Needed because the stream can end before anybody asks it to — the
    /// microphone was unplugged, the recogniser gave up — and in that case there
    /// are no last words still to come. Waiting for them anyway would hang the
    /// dictation forever on the one path where the hardware has already failed.
    private var streamIsOpen = false

    /// Whoever is waiting for the recogniser's last words, resolved when the
    /// transcriber's stream ends.
    private var settleWaiter: CheckedContinuation<String, any Error>?

    /// The cleanup and its deadline, racing, and whoever is waiting for the
    /// first of them to finish.
    private var race: Race?

    private struct Race {
        let waiter: CheckedContinuation<String, any Error>
        let contenders: [Task<Void, Never>]
    }

    private var progress: DictationProgress?

    public init(
        transcriber: any Transcriber,
        refiner: (any TextRefiner)?,
        clipboard: any Clipboard,
        keyboard: any KeyboardSender,
        focus: any FocusGuard,
        settings: @escaping @Sendable () async -> Settings,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcriber = transcriber
        self.refiner = refiner
        self.clipboard = clipboard
        self.keyboard = keyboard
        self.focus = focus
        self.readSettings = settings
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Watching

    /// A stream of everything that happens, starting with the state as it is
    /// now — so that an interface which subscribes late is not left blank until
    /// the next dictation.
    public func events() -> AsyncStream<DictationEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(.state(state))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    public var currentState: DictationState { state }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func emit(_ event: DictationEvent) {
        for continuation in listeners.values { continuation.yield(event) }
    }

    private func move(to newState: DictationState) {
        state = newState
        emit(.state(newState))
    }

    private func updateProgress(_ change: (inout DictationProgress) -> Void) {
        guard var progress else { return }
        change(&progress)
        self.progress = progress
        emit(.progress(progress))
    }

    // MARK: - The two verbs

    /// Starts a dictation, or ends the one in progress.
    ///
    /// A press that arrives while the recogniser is still starting, or while
    /// the transcript is already on its way, is ignored rather than queued: the
    /// user pressed it because nothing had happened yet, and starting a second
    /// dictation on top of the first is never what they meant.
    public func toggle(destination: DictationDestination = .insertion) async {
        guard !isStarting else { return }
        switch state {
        case .idle, .failed:
            await beginRecording(destination: destination)
        case .recording:
            await finishRecording()
        case .settling, .refining, .delivering:
            break
        }
    }

    /// Throws the dictation away, from wherever it had got to.
    ///
    /// Reachable from every state and never delivers anything. Cancelling when
    /// there is nothing to cancel is not an error — the user cannot always tell,
    /// which is exactly why they pressed it.
    public func cancel() async {
        if isStarting {
            // `beginRecording` sees this once the transcriber has started, and
            // cancels it then: there is nothing to cancel until it has.
            cancelRequested = true
            return
        }
        guard state.isBusy else {
            if case .failed = state { move(to: .idle) }
            return
        }

        // All of it before the first await. Anything still in flight resumes
        // to find the generation changed and stops, rather than carrying on
        // while the transcriber is being cancelled.
        generation += 1
        consumer?.cancel()
        consumer = nil
        streamIsOpen = false
        resumeSettleWaiter(with: .failure(CancellationError()))
        finishRace(with: .failure(CancellationError()))
        settled = ""
        volatile = ""
        progress = nil
        move(to: .idle)

        let cancelling = Task { await transcriber.cancel() }
        self.cancelling = cancelling
        await cancelling.value
    }

    // MARK: - Recording

    private func beginRecording(destination: DictationDestination) async {
        isStarting = true
        cancelRequested = false
        defer { isStarting = false }

        generation += 1
        let current = generation
        settled = ""
        volatile = ""
        progress = nil

        // Before anything appears on screen. Showing the indicator can take the
        // keyboard away from the window the text is headed for, and by then it
        // is too late to note where it was.
        focus.remember()

        await cancelling?.value

        let stream: AsyncThrowingStream<TranscriptUpdate, any Error>
        do {
            stream = try await transcriber.start()
        } catch {
            if cancelRequested {
                if state != .idle { move(to: .idle) }
            } else {
                move(to: .failed(message: Self.describe(error)))
            }
            return
        }

        if cancelRequested {
            await transcriber.cancel()
            if state != .idle { move(to: .idle) }
            return
        }

        streamIsOpen = true
        let started = DictationProgress(destination: destination, startedAt: now())
        progress = started
        emit(.progress(started))
        move(to: .recording(text: "", destination: destination))

        consumer = Task { [weak self] in
            do {
                for try await update in stream {
                    await self?.absorb(update, from: current)
                }
                await self?.streamEnded(with: nil, from: current)
            } catch {
                await self?.streamEnded(with: error, from: current)
            }
        }
    }

    private func absorb(_ update: TranscriptUpdate, from dictation: Int) {
        guard dictation == generation else { return }
        settled = update.settled
        volatile = update.volatile
        // Only while recording: an update that arrives during settling is part
        // of the final transcript, not something to redraw an indicator with.
        if case .recording(_, let destination) = state {
            move(to: .recording(text: update.text, destination: destination))
        }
    }

    private func streamEnded(with error: (any Error)?, from dictation: Int) async {
        // A cancelled consumer's stream ends as if it had finished normally.
        // Taken for the end of the recording, that pastes what was cancelled.
        guard dictation == generation else { return }
        streamIsOpen = false
        if let error {
            resumeSettleWaiter(with: .failure(error))
            // Nobody waiting means the recogniser fell over mid-recording,
            // which the user has not been told about yet.
            if case .recording = state {
                move(to: .failed(message: Self.describe(error)))
            }
            return
        }
        resumeSettleWaiter(with: .success(transcript))

        // The stream finished on its own while still recording: the microphone
        // went away, or the recogniser decided it had heard enough. Treat what
        // it did hear as the dictation rather than discarding it.
        if case .recording = state {
            await finishRecording()
        }
    }

    private var transcript: String {
        TranscriptUpdate(settled: settled, volatile: volatile).text.trimmed
    }

    private func resumeSettleWaiter(with result: Result<String, any Error>) {
        guard let waiter = settleWaiter else { return }
        settleWaiter = nil
        waiter.resume(with: result)
    }

    // MARK: - Stopping, and everything after it

    private func finishRecording() async {
        guard case .recording(_, let destination) = state else { return }
        let current = generation
        let ended = now()
        updateProgress { $0.recordingEndedAt = ended }
        move(to: .settling)

        let text: String
        do {
            text = try await stopAndWaitForLastWords()
        } catch {
            // A cancel resolves the wait with an error of its own; it has
            // already put the session back to idle.
            guard current == generation else { return }
            move(to: .failed(message: Self.describe(error)))
            return
        }
        guard current == generation else { return }

        consumer = nil
        let ready = now()
        updateProgress {
            $0.transcriptReadyAt = ready
            $0.rawTranscript = text
        }

        // Nothing said. Not a failure and not worth a message: the user pressed
        // the key twice, or thought better of it.
        guard !text.isEmpty else {
            move(to: .idle)
            return
        }

        switch destination {
        case .agent:
            // Handed over untouched. Cleanup rules are for prose going into a
            // document; a question does not want its filler words removed by a
            // second agent first.
            emit(.agentPrompt(text))
            move(to: .idle)
        case .insertion:
            guard let final = await refined(text) else { return }
            await deliver(final)
        }
    }

    /// Stops the audio and waits for the recogniser to commit to the last of
    /// what it heard — which is a moment after the sound stops, and the reason
    /// this is not simply `transcript`.
    private func stopAndWaitForLastWords() async throws -> String {
        // Already over: the microphone went away, or the recogniser stopped by
        // itself. What it heard before that is the whole dictation.
        guard streamIsOpen else { return transcript }

        let current = generation
        return try await withCheckedThrowingContinuation { continuation in
            settleWaiter = continuation
            Task {
                do {
                    try await transcriber.stop()
                } catch {
                    // Already on the actor: the task inherits its isolation.
                    guard current == self.generation else { return }
                    self.resumeSettleWaiter(with: .failure(error))
                }
            }
        }
    }

    // MARK: - Cleanup

    /// The cleaned-up text, or the raw transcript and a word about why. Nil
    /// only when the dictation was cancelled on the way.
    ///
    /// Never fails otherwise. A dictation that arrives uncleaned is a small
    /// disappointment; one that disappears because a subprocess exited 1 is a
    /// reason to stop using the application.
    private func refined(_ raw: String) async -> String? {
        let current = generation
        let settings = await readSettings()
        guard current == generation else { return nil }

        let timeout = max(1, settings.refinerTimeoutSeconds)
        let started = now()
        func cleanupProgress(_ outcome: CleanupProgress.Outcome) -> CleanupProgress {
            CleanupProgress(engine: settings.cleanupEngine, startedAt: started,
                            deadlineSeconds: timeout, outcome: outcome)
        }

        guard settings.cleanupEnabled, let refiner, !settings.rules.isEmpty else {
            let reason: CleanupProgress.SkipReason =
                !settings.cleanupEnabled ? .disabled : refiner == nil ? .noRefiner : .noRules
            updateProgress { $0.cleanup = cleanupProgress(.skipped(reason)) }
            return raw
        }

        updateProgress { $0.cleanup = cleanupProgress(.running) }
        move(to: .refining)
        let instruction = settings.rules.instruction(language: settings.language)

        let outcome: Result<String, any Error>
        do {
            outcome = .success(try await withDeadline(seconds: timeout) {
                try await refiner.refine(text: CleanupRuleSet.enclosing(raw), instruction: instruction)
            })
        } catch {
            outcome = .failure(error)
        }
        guard current == generation else { return nil }

        let reason: String
        switch outcome {
        case .success(let cleaned) where !cleaned.trimmed.isEmpty:
            let finished = now()
            updateProgress { $0.cleanup?.outcome = .cleaned(cleaned.trimmed, finishedAt: finished) }
            return cleaned.trimmed
        case .success:
            // An empty reply is not a cleaned-up transcript, whatever the agent
            // meant by it.
            reason = "Temizleme boş döndü"
        case .failure(let error) where error is DeadlineExceeded:
            reason = "Temizleme \(timeout) saniyeden uzun sürdü"
        case .failure(let error):
            reason = "Temizleme başarısız (\(Self.describe(error)))"
        }
        let finished = now()
        updateProgress { $0.cleanup?.outcome = .fellBack(reason: reason, finishedAt: finished) }
        emit(.notice("\(reason), bu yüzden ham metin kullanıldı."))
        return raw
    }

    private struct DeadlineExceeded: Error {}

    /// Races the work against the clock and abandons it if the clock wins.
    ///
    /// Two unstructured tasks rather than a task group, because a group cannot
    /// return until its losing child has: a refiner that ignores cancellation
    /// would hold the dictation in `.refining` long past its deadline. The loser
    /// is cancelled and never awaited, and `cancel()` can end the race too.
    private func withDeadline(
        seconds: Int,
        _ work: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let current = generation
        let sleep = self.sleep
        return try await withCheckedThrowingContinuation { continuation in
            // Both inherit the actor, so neither can finish the race before it
            // has been set up below.
            let working = Task {
                let result: Result<String, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                guard current == self.generation else { return }
                self.finishRace(with: result)
            }
            let clock = Task {
                guard (try? await sleep(.seconds(seconds))) != nil else { return }
                guard current == self.generation else { return }
                self.finishRace(with: .failure(DeadlineExceeded()))
            }
            race = Race(waiter: continuation, contenders: [working, clock])
        }
    }

    private func finishRace(with result: Result<String, any Error>) {
        guard let race else { return }
        self.race = nil
        for contender in race.contenders { contender.cancel() }
        race.waiter.resume(with: result)
    }

    // MARK: - Delivery

    private func deliver(_ text: String) async {
        let current = generation
        let settings = await readSettings()
        guard current == generation else { return }

        updateProgress { $0.delivery = settings.delivery }
        move(to: .delivering)

        switch settings.delivery {
        case .paste, .clipboardOnly:
            clipboard.setText(text)
        case .type:
            // Left alone on purpose: typing exists for the times the clipboard
            // is not the user's to overwrite.
            break
        }

        // Before the key press, not after. The indicator may have taken the
        // keyboard from the window the text is going to, and a paste that
        // arrives while it still holds it goes nowhere.
        focus.restore()

        do {
            switch settings.delivery {
            case .paste:
                try keyboard.paste()
            case .type:
                try keyboard.type(text)
            case .clipboardOnly:
                break
            }
        } catch {
            // The text is on the clipboard in the paste case, so this is
            // recoverable by hand and worth saying rather than throwing.
            move(to: .failed(message: Self.describe(error)))
            return
        }

        let delivered = now()
        updateProgress { $0.deliveredAt = delivered }
        move(to: .idle)
    }

    // MARK: -

    /// A message for a person rather than a debugger. The typed port errors
    /// carry their own wording; anything else is shown as it is, because a
    /// half-hidden reason is worse than an ugly one.
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as TranscriptionFailure:
            switch failure {
            case .languageUnavailable(let language):
                "macOS'ta \(language) için konuşma modeli yok."
            case .modelNotInstalled(let language):
                "\(language) için konuşma modeli henüz indirilmemiş."
            case .notPermitted(let kind):
                switch kind {
                case .microphone: "Diktaf'ın mikrofonu kullanma izni yok."
                case .speechRecognition: "Diktaf'ın konuşma tanıma izni yok."
                case .keyboardControl: "Diktaf'ın tuşlara basma izni yok."
                }
            case .audioUnavailable(let detail):
                "Mikrofon kullanılamıyor: \(detail)"
            case .underlying(let detail):
                detail
            }
        case let failure as RefinementFailure:
            switch failure {
            case .agentUnavailable(let detail): "Yerel agent yok: \(detail)"
            case .agentFailed(let detail): detail
            case .emptyReply: "Boş yanıt geldi."
            case .timedOut(let seconds): "Yanıt \(seconds) saniyeden uzun sürdü."
            }
        default:
            String(describing: error)
        }
    }
}
