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

    private var state: DictationState = .idle
    private var listeners: [UUID: AsyncStream<DictationEvent>.Continuation] = [:]

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

    public init(
        transcriber: any Transcriber,
        refiner: (any TextRefiner)?,
        clipboard: any Clipboard,
        keyboard: any KeyboardSender,
        focus: any FocusGuard,
        settings: @escaping @Sendable () async -> Settings,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.transcriber = transcriber
        self.refiner = refiner
        self.clipboard = clipboard
        self.keyboard = keyboard
        self.focus = focus
        self.readSettings = settings
        self.sleep = sleep
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

    // MARK: - The two verbs

    /// Starts a dictation, or ends the one in progress.
    ///
    /// A press that arrives while the transcript is already on its way is
    /// ignored rather than queued: the user pressed it because nothing had
    /// happened yet, and starting a second dictation on top of the first is
    /// never what they meant.
    public func toggle(destination: DictationDestination = .insertion) async {
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
        guard state.isBusy else {
            if case .failed = state { move(to: .idle) }
            return
        }

        consumer?.cancel()
        consumer = nil
        streamIsOpen = false
        await transcriber.cancel()
        resumeSettleWaiter(with: .failure(CancellationError()))
        settled = ""
        volatile = ""
        move(to: .idle)
    }

    // MARK: - Recording

    private func beginRecording(destination: DictationDestination) async {
        settled = ""
        volatile = ""

        // Before anything appears on screen. Showing the indicator can take the
        // keyboard away from the window the text is headed for, and by then it
        // is too late to note where it was.
        focus.remember()

        let stream: AsyncThrowingStream<TranscriptUpdate, any Error>
        do {
            stream = try await transcriber.start()
        } catch {
            move(to: .failed(message: Self.describe(error)))
            return
        }

        streamIsOpen = true
        move(to: .recording(text: "", destination: destination))

        consumer = Task { [weak self] in
            do {
                for try await update in stream {
                    await self?.absorb(update)
                }
                await self?.streamEnded(with: nil)
            } catch is CancellationError {
                // cancel() has already put the session back to idle.
            } catch {
                await self?.streamEnded(with: error)
            }
        }
    }

    private func absorb(_ update: TranscriptUpdate) {
        settled = update.settled
        volatile = update.volatile
        // Only while recording: an update that arrives during settling is part
        // of the final transcript, not something to redraw an indicator with.
        if case .recording(_, let destination) = state {
            move(to: .recording(text: update.text, destination: destination))
        }
    }

    private func streamEnded(with error: (any Error)?) async {
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
        move(to: .settling)

        let text: String
        do {
            text = try await stopAndWaitForLastWords()
        } catch is CancellationError {
            return                       // cancel() has taken it from here
        } catch {
            move(to: .failed(message: Self.describe(error)))
            return
        }

        consumer = nil

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
            await deliver(await refined(text))
        }
    }

    /// Stops the audio and waits for the recogniser to commit to the last of
    /// what it heard — which is a moment after the sound stops, and the reason
    /// this is not simply `transcript`.
    private func stopAndWaitForLastWords() async throws -> String {
        // Already over: the microphone went away, or the recogniser stopped by
        // itself. What it heard before that is the whole dictation.
        guard streamIsOpen else { return transcript }

        return try await withCheckedThrowingContinuation { continuation in
            settleWaiter = continuation
            Task {
                do {
                    try await transcriber.stop()
                } catch {
                    // Already on the actor: the task inherits its isolation.
                    self.resumeSettleWaiter(with: .failure(error))
                }
            }
        }
    }

    // MARK: - Cleanup

    /// The cleaned-up text, or the raw transcript and a word about why.
    ///
    /// Never throws. A dictation that arrives uncleaned is a small
    /// disappointment; one that disappears because a subprocess exited 1 is a
    /// reason to stop using the application.
    private func refined(_ raw: String) async -> String {
        let settings = await readSettings()
        guard settings.cleanupEnabled, let refiner, !settings.rules.isEmpty else {
            return raw
        }

        move(to: .refining)
        let instruction = settings.rules.instruction(language: settings.language)
        let timeout = max(1, settings.refinerTimeoutSeconds)

        do {
            let cleaned = try await withDeadline(seconds: timeout) {
                try await refiner.refine(text: raw, instruction: instruction)
            }
            let trimmed = cleaned.trimmed
            // An empty reply is not a cleaned-up transcript, whatever the agent
            // meant by it.
            guard !trimmed.isEmpty else {
                emit(.notice("Cleanup returned nothing, so this is the raw transcript."))
                return raw
            }
            return trimmed
        } catch is DeadlineExceeded {
            emit(.notice("Cleanup took longer than \(timeout)s, so this is the raw transcript."))
            return raw
        } catch {
            emit(.notice("Cleanup failed (\(Self.describe(error))), so this is the raw transcript."))
            return raw
        }
    }

    private struct DeadlineExceeded: Error {}

    /// Races the work against the clock and abandons it if the clock wins.
    ///
    /// The loser is cancelled either way, so a refiner still waiting on a
    /// process does not outlive the dictation it belonged to.
    private func withDeadline<T: Sendable>(
        seconds: Int,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let sleep = self.sleep
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await sleep(.seconds(seconds))
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DeadlineExceeded() }
            return first
        }
    }

    // MARK: - Delivery

    private func deliver(_ text: String) async {
        move(to: .delivering)
        let settings = await readSettings()

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

        move(to: .idle)
    }

    // MARK: -

    /// A message for a person rather than a debugger. The typed port errors
    /// carry their own wording; anything else is shown as it is, because a
    /// half-hidden reason is worse than an ugly one.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as TranscriptionFailure:
            switch failure {
            case .languageUnavailable(let language):
                "macOS has no speech model for \(language)."
            case .modelNotInstalled(let language):
                "The speech model for \(language) is not installed yet."
            case .notPermitted(let kind):
                switch kind {
                case .microphone: "Diktaf is not allowed to use the microphone."
                case .speechRecognition: "Diktaf is not allowed to recognise speech."
                case .keyboardControl: "Diktaf is not allowed to press keys."
                }
            case .audioUnavailable(let detail):
                "No microphone: \(detail)"
            case .underlying(let detail):
                detail
            }
        case let failure as RefinementFailure:
            switch failure {
            case .agentUnavailable(let detail): "No local agent: \(detail)"
            case .agentFailed(let detail): detail
            case .emptyReply: "The agent replied with nothing."
            case .timedOut(let seconds): "The agent took longer than \(seconds)s."
            }
        default:
            String(describing: error)
        }
    }
}
