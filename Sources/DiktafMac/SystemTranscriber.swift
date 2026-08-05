import AVFoundation
import DiktafCore
import Foundation
import Speech

/// Speech to text with the recogniser built into macOS.
///
/// `SpeechAnalyzer` with the `DictationTranscriber` module, which arrived in
/// macOS 26 — not `SFSpeechRecognizer`. Two things matter for dictation: it is
/// on-device by design rather than as an option, and its progressive preset
/// reports the tail it is still revising, so the indicator can show words as they
/// are said instead of a second behind. `SpeechModelCatalogue` explains why this
/// module rather than `SpeechTranscriber`.
///
/// Audio goes in through `AVAudioEngine`. The recogniser names the format it
/// wants and the engine's input hardware provides whatever it provides, so a
/// converter sits between them; assuming they match works on the machine it was
/// written on and nowhere else.
public actor SystemTranscriber: Transcriber {
    private var requestedLocale: Locale?
    private let catalogue: SpeechModelCatalogue
    private let permissions: any PermissionAuthority

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var updates: AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Text the recogniser has committed to, and the tail it has not.
    private var settled = ""
    private var volatileTail = ""

    /// Set by `cancel()`, so a result still in flight is not yielded after the
    /// caller has said it no longer wants any.
    private var abandoned = false

    /// - Parameter locale: nil follows whatever the system is set to.
    public init(
        locale: Locale? = nil,
        catalogue: SpeechModelCatalogue = SpeechModelCatalogue(),
        permissions: any PermissionAuthority = MacPermissions()
    ) {
        self.requestedLocale = locale
        self.catalogue = catalogue
        self.permissions = permissions
    }

    /// Changes the language for the next dictation.
    ///
    /// Settable rather than fixed at construction so that changing it in the
    /// settings does not mean rebuilding the session — and so that it can only
    /// take effect between dictations, which is the only safe moment for it.
    public func use(locale: Locale?) {
        requestedLocale = locale
    }

    // MARK: - Starting

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        settled = ""
        volatileTail = ""
        abandoned = false

        try await ensureMicrophone()

        let wanted = requestedLocale ?? Locale.current
        guard let locale = await catalogue.resolve(wanted) else {
            throw TranscriptionFailure.languageUnavailable(wanted.identifier)
        }
        switch await catalogue.state(of: locale) {
        case .installed:
            break
        case .notInstalled, .downloading:
            // Not downloaded here. A first dictation that silently waits several
            // minutes for a model is indistinguishable from one that is broken,
            // so the settings window asks and shows progress.
            throw TranscriptionFailure.modelNotInstalled(locale.identifier)
        case .unsupported:
            throw TranscriptionFailure.languageUnavailable(locale.identifier)
        }

        // The progressive preset is what asks for the volatile tail. Without it
        // nothing arrives until a phrase is finished.
        let transcriber = SpeechModelCatalogue.module(for: locale)
        self.transcriber = transcriber

        guard let analyzerFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionFailure.audioUnavailable(
                "the recogniser named no audio format it can read")
        }

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (stream, updates) = AsyncThrowingStream
            .makeStream(of: TranscriptUpdate.self, throwing: (any Error).self)
        self.updates = updates

        // Started before the audio, so that no buffer is produced with nowhere
        // to go.
        resultsTask = Task { [weak self] in
            await self?.consume(transcriber.results)
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
            try startEngine(feeding: inputContinuation, converting: analyzerFormat)
        } catch let failure as TranscriptionFailure {
            await tearDown()
            throw failure
        } catch {
            await tearDown()
            throw TranscriptionFailure.underlying(String(describing: error))
        }

        // Best effort, and deliberately after the dictation is already running:
        // it keeps the system from reclaiming this model later, and failing to
        // get it is not a reason to refuse to transcribe now.
        Task { [catalogue] in await catalogue.reserve(locale) }

        return stream
    }

    /// Gets the microphone permission settled before any audio API is touched.
    ///
    /// Not a nicety, and not something the caller can be left to remember:
    /// reaching for `AVAudioEngine`'s input node without it **blocks and never
    /// returns**. It does not fail, it does not throw, and nothing is logged —
    /// the dictation simply never starts, which is indistinguishable from the
    /// hotkey never having arrived. That cost an afternoon to find, so the check
    /// lives here, in front of the only code that could hit it.
    ///
    /// `request` is the API that puts the system's prompt up and comes back with
    /// an answer, which is why asking is not the same as blocking.
    private func ensureMicrophone() async throws {
        var state = await permissions.state(of: .microphone)
        if state == .undetermined {
            state = await permissions.request(.microphone)
        }
        guard state == .granted else {
            throw TranscriptionFailure.notPermitted(.microphone)
        }

        // Asked for but never insisted on. The dictation model runs on this Mac,
        // and whether it consults this authorisation at all is not documented —
        // so refusing to transcribe over it would be inventing a requirement.
        if await permissions.state(of: .speechRecognition) == .undetermined {
            await permissions.request(.speechRecognition)
        }
    }

    private func startEngine(
        feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
        converting analyzerFormat: AVAudioFormat
    ) throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
            throw TranscriptionFailure.audioUnavailable("no input device")
        }

        let converter = BufferConverter(from: hardwareFormat, to: analyzerFormat)

        // 4096 frames is about a tenth of a second at the usual rates: short
        // enough that the indicator keeps up, long enough not to wake the audio
        // thread pointlessly.
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, time in
            // This closure runs on the audio thread. It must not allocate much,
            // must not lock, and must not touch the actor — yielding into a
            // continuation is all it does.
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: nil))
            _ = time
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            throw TranscriptionFailure.audioUnavailable(String(describing: error))
        }
    }

    // MARK: - Reading results

    private func consume(
        _ results: some AsyncSequence<DictationTranscriber.Result, any Error> & Sendable
    ) async {
        do {
            for try await result in results {
                let text = String(result.text.characters)
                if result.isFinal {
                    // Committed to. Joined with a space rather than glued: the
                    // recogniser reports a phrase at a time and does not put the
                    // separator in for you.
                    settled = settled.isEmpty ? text : "\(settled) \(text)"
                    volatileTail = ""
                } else {
                    volatileTail = text
                }
                yieldUpdate()
            }
            finish(throwing: nil)
        } catch is CancellationError {
            finish(throwing: nil)
        } catch {
            finish(throwing: TranscriptionFailure.underlying(String(describing: error)))
        }
    }

    private func yieldUpdate() {
        guard !abandoned else { return }
        updates?.yield(TranscriptUpdate(settled: settled, volatile: volatileTail))
    }

    private func finish(throwing error: (any Error)?) {
        let continuation = updates
        updates = nil
        if let error, !abandoned {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    // MARK: - Stopping

    public func stop() async throws {
        // The audio ends here; the words do not. Finalising is what makes the
        // recogniser commit to the tail it was still revising, and the results
        // sequence ends after that — which is what closes the caller's stream.
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            finish(throwing: TranscriptionFailure.underlying(String(describing: error)))
            await tearDown()
            throw TranscriptionFailure.underlying(String(describing: error))
        }
        await tearDown()
    }

    public func cancel() async {
        abandoned = true
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        finish(throwing: nil)
        await tearDown()
    }

    private func stopAudio() {
        guard let engine else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func tearDown() async {
        resultsTask = nil
        engine = nil
        analyzer = nil
        transcriber = nil
    }
}

/// Turns the microphone's buffers into the format the recogniser asked for.
///
/// `@unchecked Sendable` and justified: the converter is created before the tap
/// is installed and afterwards is touched only from inside the tap block, which
/// the audio system calls serially on one thread. Nothing else holds a reference.
private final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.outputFormat = output
        self.ratio = output.sampleRate / input.sampleRate
        // Nil when the formats already match, which saves a copy per buffer on
        // the machines where they do.
        self.converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        self.converter?.primeMethod = .none
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }

        // Rounded up with a frame to spare: a sample rate conversion can produce
        // one more frame than the arithmetic suggests, and a buffer one frame too
        // small loses audio silently.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: capacity) else { return nil }

        // The block is asked for input repeatedly and must say "no more" the
        // second time, or the converter loops. Both the flag and the buffer live
        // in the box because the block is typed as @Sendable even though the
        // converter calls it synchronously, on this thread, before returning.
        let pending = PendingInput(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// One buffer, handed over once.
///
/// `@unchecked Sendable` for the same reason as `BufferConverter`: it exists for
/// the duration of one synchronous `convert` call on the audio thread.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
