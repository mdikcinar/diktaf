import AVFoundation
import DiktafCore
import Foundation
import Speech
import Synchronization

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

    /// What the tap measures for the level meter. Nil when not recording.
    private var meter: InputMeter?

    /// Text the recogniser has committed to, and the tail it has not.
    private var settled = ""
    private var volatileTail = ""

    /// Counted up by `start()` and `cancel()`. Results, finalising and teardown
    /// all come after an await and compare it first, so a late stop cannot close
    /// the next dictation's stream or take its analyzer away.
    private var dictation = 0

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

    // MARK: - What the indicator shows

    /// How loud the microphone is, from 0 for a quiet room to 1 for a raised
    /// voice, and 0 when nothing is being recorded. Smoothed, so that a meter
    /// drawn from it falls back rather than flickering.
    public func inputLevel() -> Float {
        meter?.level ?? 0
    }

    /// The same, unscaled and unsmoothed: the last buffer's RMS in dBFS, and −∞
    /// when nothing is being recorded. For telling speech from the room, which
    /// the meter's floor would hide at a low input volume.
    public func inputDecibels() -> Float {
        meter?.decibels ?? -.infinity
    }

    /// How much has been recorded so far in this dictation, and 0 when nothing
    /// is being recorded.
    public func recordedSeconds() -> Double {
        meter?.seconds ?? 0
    }

    // MARK: - Starting

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        // One recording at a time: a second engine on the same input would be
        // left running by the first one's stop.
        guard engine?.isRunning != true else {
            throw TranscriptionFailure.underlying("Zaten süren bir dikte var.")
        }
        dictation += 1
        let ours = dictation

        // A stream an earlier dictation left open is closed rather than left
        // for this one to share.
        finish(throwing: nil)
        settled = ""
        volatileTail = ""

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

        guard let analyzerFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionFailure.audioUnavailable(
                "tanıyıcı okuyabileceği bir ses biçimi bildirmedi")
        }

        // Everything so far only asked questions. From here on this dictation
        // holds things, so it has to still be the current one.
        guard dictation == ours else { throw CancellationError() }
        self.transcriber = transcriber

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
            await self?.consume(transcriber.results, of: ours)
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
            guard dictation == ours else { throw CancellationError() }
            try startEngine(feeding: inputContinuation, converting: analyzerFormat)
        } catch {
            // Nothing of a start that failed may outlive it: not the analyzer,
            // not the task waiting on its results, and not a stream nobody will
            // ever finish.
            inputContinuation.finish()
            if dictation == ours {
                stopAudio()
                self.inputContinuation = nil
                resultsTask?.cancel()
                finish(throwing: nil)
                tearDown()
            }
            await analyzer.cancelAndFinishNow()
            switch error {
            case let failure as TranscriptionFailure: throw failure
            case is CancellationError: throw error
            default: throw TranscriptionFailure.underlying(String(describing: error))
            }
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
            throw TranscriptionFailure.audioUnavailable("giriş aygıtı yok")
        }

        let converter = try BufferConverter(from: hardwareFormat, to: analyzerFormat)
        let meter = InputMeter(sampleRate: hardwareFormat.sampleRate)
        self.meter = meter

        // 4096 frames is about a tenth of a second at the usual rates: short
        // enough that the indicator keeps up, long enough not to wake the audio
        // thread pointlessly.
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, time in
            // This closure runs on the audio thread. It must not allocate much,
            // must not lock, and must not touch the actor — measuring the level
            // into atomics and yielding into a continuation is all it does.
            meter.measure(buffer)
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
        _ results: some AsyncSequence<DictationTranscriber.Result, any Error> & Sendable,
        of ours: Int
    ) async {
        do {
            for try await result in results {
                guard dictation == ours else { return }
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
            guard dictation == ours else { return }
            finish(throwing: nil)
        } catch is CancellationError {
            guard dictation == ours else { return }
            finish(throwing: nil)
        } catch {
            guard dictation == ours else { return }
            finish(throwing: TranscriptionFailure.underlying(String(describing: error)))
        }
    }

    private func yieldUpdate() {
        updates?.yield(TranscriptUpdate(settled: settled, volatile: volatileTail))
    }

    private func finish(throwing error: (any Error)?) {
        let continuation = updates
        updates = nil
        if let error {
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
        let ours = dictation
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil

        // Kept on the actor while it finalises, so that a `cancel()` during the
        // wait reaches it.
        guard let analyzer else { return }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            guard dictation == ours else { return }
            let failure = TranscriptionFailure.underlying(String(describing: error))
            finish(throwing: failure)
            tearDown()
            throw failure
        }
        guard dictation == ours else { return }
        tearDown()
    }

    public func cancel() async {
        dictation += 1
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        finish(throwing: nil)
        tearDown()
        // Last, and on the one captured above: by the time it returns, a new
        // dictation may already have started.
        await analyzer?.cancelAndFinishNow()
    }

    private func stopAudio() {
        meter = nil
        guard let engine else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func tearDown() {
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

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        self.outputFormat = output
        self.ratio = output.sampleRate / input.sampleRate
        // Nil when the formats already match, which saves a copy per buffer on
        // the machines where they do.
        if input == output {
            self.converter = nil
        } else if let converter = AVAudioConverter(from: input, to: output) {
            converter.primeMethod = .none
            self.converter = converter
        } else {
            // Not passed through as if they matched: the recogniser would be
            // handed audio in a format it never asked for.
            throw TranscriptionFailure.audioUnavailable(
                "mikrofonun \(input) biçiminden tanıyıcının \(output) biçimine dönüştürücü yok")
        }
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

/// The microphone's level and how much it has recorded, measured in the tap.
/// Atomics rather than a lock because the tap runs on the audio thread; only it
/// writes, and a reading one buffer stale is still the right reading.
final class InputMeter: Sendable {
    private let levelBits = Atomic<UInt32>(0)
    private let decibelBits = Atomic<UInt32>((-Float.infinity).bitPattern)
    private let frames = Atomic<Int>(0)
    private let sampleRate: Double

    /// The quietest level a meter shows anything for, in dBFS.
    static let meterFloor: Float = -50
    /// The level a meter shows as full, in dBFS. A voice at dictation distance
    /// peaks around here, so a meter that only fills for shouting reads as dead.
    static let meterCeiling: Float = -10
    /// How much of the previous level survives each buffer, which is about a
    /// tenth of a second: high enough that the meter falls rather than flickers.
    static let meterDecay: Float = 0.7

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func measure(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        frames.wrappingAdd(count, ordering: .relaxed)
        guard count > 0, let samples = buffer.floatChannelData?[0] else { return }

        var sumOfSquares: Float = 0
        for index in 0..<count {
            sumOfSquares += samples[index] * samples[index]
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        let next = max(Self.level(ofRMS: rms), level * Self.meterDecay)
        levelBits.store(next.bitPattern, ordering: .relaxed)
        decibelBits.store((20 * log10(rms)).bitPattern, ordering: .relaxed)
    }

    var level: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }

    var decibels: Float { Float(bitPattern: decibelBits.load(ordering: .relaxed)) }

    var seconds: Double {
        sampleRate > 0 ? Double(frames.load(ordering: .relaxed)) / sampleRate : 0
    }

    /// An RMS level as a meter reading: 0 at `meterFloor` and below, 1 at
    /// `meterCeiling` and above, in proportion to the decibels in between.
    static func level(ofRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - meterFloor) / (meterCeiling - meterFloor)))
    }
}
