import DiktafCore
import Foundation
import Synchronization
import WhisperKit

/// Speech to text with Whisper, run locally through Core ML.
///
/// ## Why this looks nothing like `SystemTranscriber`
///
/// Apple's recogniser is a streaming model: audio goes in continuously and words
/// come out continuously, already divided into what it has committed to and what
/// it is still revising. Whisper is not. Whisper takes a *recording* — up to
/// thirty seconds of it — and returns the whole transcript at once. There is no
/// running commentary to subscribe to.
///
/// So the two halves of `TranscriptUpdate` are earned differently here:
///
/// * **volatile** is a preview. While recording, the audio so far is transcribed
///   again from scratch, over and over, and each result replaces the last. It is
///   what the indicator shows, it is thrown away, and it is allowed to be wrong.
/// * **settled** is produced exactly once, by `stop()`, from a single pass over
///   the entire recording.
///
/// That last point is not a compromise — it is the better of the two designs for
/// this model. Whisper reads a whole utterance at a time and uses the end of a
/// sentence to decide the beginning of it, so one pass over everything beats any
/// number of passes over pieces. The preview exists so the user can see that
/// something is being heard; the transcript comes from the final pass.
///
/// ## Where the audio comes from
///
/// WhisperKit's own `AudioProcessor`, and it is owned here rather than left to
/// the pipeline. Loading a Whisper model takes seconds, and a dictation that
/// starts recording only once the model is ready loses the beginning of the
/// sentence — which is the part that decides what the rest of it means. Owning
/// the microphone separately means the recording starts on the key press and the
/// model catches up.
public actor WhisperTranscriber: Transcriber {
    private let catalogue: WhisperModelCatalogue
    private let permissions: any PermissionAuthority

    private var requestedModel: WhisperModel
    private var requestedLocale: Locale?

    /// Kept between dictations. Loading is the expensive part and the weights do
    /// not change; discarding this after every sentence would mean paying for it
    /// again every time.
    private var pipeline: WhisperKit?
    private var loadedVariant: String?

    /// The load in flight and everyone waiting on it. One at a time: launch,
    /// preview and stop can all ask within a second, and each loading its own
    /// copy is several times the memory for the same weights.
    private var loadingVariant: String?
    private var loadWaiters: [CheckedContinuation<Void, any Error>] = []

    /// One microphone for the lifetime of this object, emptied between
    /// dictations. Recreating it per dictation means re-entering the audio
    /// hardware every time, and the samples are the only state it carries.
    private let microphone = AudioProcessor()

    /// The dictation's audio as it arrives, for the preview and the level meter.
    /// Nil when not recording.
    private var live: LiveRecording?

    private var updates: AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation?
    private var previewTask: Task<Void, Never>?
    private var finalPass: Task<String, any Error>?
    private var recording = false

    private var settled = ""
    private var volatileTail = ""

    /// Counted up by `start()` and `cancel()`. Whatever awaits compares it
    /// afterwards, so a pass that outlives its dictation lands nowhere rather
    /// than in whichever dictation is running by then.
    private var dictation = 0

    /// Whisper's window, and the bound on how much audio a preview pass reads.
    ///
    /// The model cannot see further back than thirty seconds however much it is
    /// handed, so a preview over the last thirty is the same preview as one over
    /// the last five minutes — at a fraction of the cost, and at a cost that
    /// stops growing with the length of the dictation. The final pass is handed
    /// everything, because there WhisperKit does seek through the whole thing.
    private static let previewWindowSeconds = 30

    private static let sampleRate = WhisperKit.sampleRate

    /// How long between preview passes.
    ///
    /// Longer than it looks like it should be. A pass over the audio so far is
    /// not free — on a large model it is a good fraction of a second — and
    /// asking for previews faster than they complete just means the machine is
    /// permanently transcribing and the words appear no sooner.
    private static let previewInterval = Duration.milliseconds(900)

    /// RMS of a tenth of a second that counts as somebody talking: -40 dBFS, well
    /// above a quiet room's -60. Low on purpose — noise let through can still be
    /// filtered from the output, while a quiet speaker shut out loses the dictation.
    static let speechEnergyThreshold: Float = 0.01

    /// How much of a recording has to be that loud before Whisper is shown it.
    /// Enough to pass a short word, too much for a key click or a cough.
    static let minimumSpeechSeconds: Float = 0.3

    public init(
        model: WhisperModel = WhisperModelCatalogue.recommended,
        locale: Locale? = nil,
        catalogue: WhisperModelCatalogue = WhisperModelCatalogue(),
        permissions: any PermissionAuthority
    ) {
        self.requestedModel = model
        self.requestedLocale = locale
        self.catalogue = catalogue
        self.permissions = permissions
    }

    // MARK: - Choosing

    /// Changes the language for the next dictation.
    ///
    /// Unlike Apple's recogniser there is no model to swap: one set of Whisper
    /// weights covers every language it knows. This only decides whether the
    /// language is told to the model or left for it to work out.
    public func use(locale: Locale?) {
        requestedLocale = locale
    }

    /// Changes the weights for the next dictation.
    ///
    /// Anything already loaded is dropped, because keeping it would mean the
    /// setting appeared to do nothing until the application was restarted.
    public func use(model: WhisperModel) {
        guard model.variant != requestedModel.variant else { return }
        requestedModel = model
        if loadedVariant != model.variant {
            pipeline = nil
            loadedVariant = nil
        }
    }

    /// Gets the model into memory before anybody presses a key.
    ///
    /// Worth calling at launch, and worth calling from nowhere that a user is
    /// waiting: the first load after a restart takes seconds, and paid here it is
    /// paid while nothing is happening rather than in the middle of a sentence.
    /// Failures are the caller's to ignore — this is an optimisation, and a
    /// dictation will load the model itself if this did not.
    public func prepare() async throws {
        _ = try await loadedPipeline()
    }

    /// Whether a dictation could start right now, or what is missing.
    public func modelState() -> WhisperModelCatalogue.ModelState {
        catalogue.state(of: requestedModel)
    }

    public var model: WhisperModel { requestedModel }

    /// Whether the chosen model is in memory.
    public enum LoadState: Sendable, Equatable {
        case notLoaded
        case loading
        case loaded
    }

    /// Whether the chosen model is in memory, on its way, or neither — so the
    /// indicator can say that the recording is running while the model loads.
    public var loadState: LoadState {
        if pipeline != nil, loadedVariant == requestedModel.variant { return .loaded }
        return loadingVariant == nil ? .notLoaded : .loading
    }

    // MARK: - What the indicator shows

    /// How loud the microphone is, from 0 for a quiet room to 1 for a raised
    /// voice, and 0 when nothing is being recorded. Smoothed, so that a meter
    /// drawn from it falls back rather than flickering.
    public func inputLevel() -> Float {
        recording ? live?.level ?? 0 : 0
    }

    /// How much has been recorded so far in this dictation, and 0 when nothing
    /// is being recorded.
    public func recordedSeconds() -> Double {
        guard recording, let live else { return 0 }
        return Double(live.sampleCount) / Double(Self.sampleRate)
    }

    // MARK: - Starting

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        // One recording at a time: a second one would share this microphone,
        // and the first one's stop would end both.
        guard !recording else {
            throw TranscriptionFailure.underlying("Zaten süren bir Whisper diktesi var.")
        }
        dictation += 1
        let ours = dictation

        // A final pass nobody waited for is overtaken, and a stream an earlier
        // dictation left open is closed rather than left for this one to share.
        finalPass?.cancel()
        finalPass = nil
        finish(throwing: nil)
        settled = ""
        volatileTail = ""

        try await ensureMicrophone()
        guard dictation == ours else { throw CancellationError() }

        guard catalogue.state(of: requestedModel) == .installed else {
            throw TranscriptionFailure.modelNotInstalled(requestedModel.label)
        }

        // Emptied here rather than after the last dictation, so that a crash or a
        // cancel between the two cannot leave yesterday's audio to be transcribed
        // as part of today's sentence.
        microphone.purgeAudioSamples(keepingLast: 0)

        let live = LiveRecording(window: Self.previewWindowSeconds * Self.sampleRate)
        do {
            // `@Sendable` so it is not taken as isolated to this actor: it is
            // called on the audio thread.
            try microphone.startRecordingLive(callback: { @Sendable samples in
                live.append(samples)
            })
        } catch {
            throw TranscriptionFailure.audioUnavailable(String(describing: error))
        }
        self.live = live
        recording = true

        let (stream, updates) = AsyncThrowingStream
            .makeStream(of: TranscriptUpdate.self, throwing: (any Error).self)
        self.updates = updates

        // Not awaited, and that is the whole point of starting the audio first:
        // the model loads while the user is already talking.
        previewTask = Task { [weak self] in await self?.preview(of: ours) }

        return stream
    }

    /// Gets the microphone permission settled before any audio API is touched.
    ///
    /// The same reasoning as in `SystemTranscriber`, for the same reason: this
    /// ends up in `AVAudioEngine`'s input node too, by way of WhisperKit, and
    /// reaching it without permission **blocks and never returns** rather than
    /// failing. Two engines, one trap, so the check is in front of both.
    private func ensureMicrophone() async throws {
        var state = await permissions.state(of: .microphone)
        if state == .undetermined {
            state = await permissions.request(.microphone)
        }
        guard state == .granted else {
            throw TranscriptionFailure.notPermitted(.microphone)
        }
    }

    // MARK: - The preview

    private func preview(of ours: Int) async {
        // Loaded inside the loop's task rather than before it so that a model
        // which fails to load does not also lose the recording: the audio is
        // already being captured, and `stop()` can still transcribe it if the
        // load succeeds by then.
        guard let pipeline = try? await loadedPipeline() else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: Self.previewInterval)
            guard !Task.isCancelled, dictation == ours, recording, let live else { return }

            // Under a second, or nothing in it louder than the room: a pass over
            // either can only make something up.
            let samples = live.recentSamples
            guard samples.count > Self.sampleRate, Self.containsSpeech(samples) else { continue }

            guard let text = try? await transcribe(samples, with: pipeline) else { continue }
            guard !Task.isCancelled, dictation == ours, recording else { return }
            volatileTail = text
            yieldUpdate()
        }
    }

    private func transcribe(_ samples: [Float], with pipeline: WhisperKit) async throws -> String {
        let results = try await pipeline.transcribe(
            audioArray: samples, decodeOptions: decodingOptions())
        return WhisperOutput.transcript(of: results)
    }

    /// Whether anybody is audibly talking in these samples, by the energy of
    /// each tenth of a second.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let frames = EnergyVAD(energyThreshold: speechEnergyThreshold).voiceActivity(in: samples)
        let loudSeconds = Float(frames.lazy.filter { $0 }.count) * 0.1
        return loudSeconds >= minimumSpeechSeconds
    }

    /// What to tell the model before it starts guessing.
    ///
    /// `language` is named rather than detected whenever the user has chosen one.
    /// Left to detect, Whisper decides from the first few seconds and then commits
    /// — and a Turkish sentence that opens with an English product name is exactly
    /// the case it gets wrong, after which it transcribes the rest as English.
    ///
    /// `temperature: 0` and no fallbacks: this is dictation, so the likeliest
    /// reading of what was said is always the one wanted, and a retry at a higher
    /// temperature costs a second to produce a guess nobody asked for.
    private func decodingOptions() -> DecodingOptions {
        let language = requestedLocale?.language.languageCode?.identifier
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Voice activity decides where the windows fall, so a pause becomes a
            // boundary instead of a sentence being cut across two windows.
            chunkingStrategy: .vad)
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
        guard recording else { return }
        recording = false
        let ours = dictation
        microphone.stopRecording()
        live = nil

        // The processor's own samples, not the live copy: that holds only the last
        // thirty seconds and misses the buffers before WhisperKit sets its callback.
        // With the tap removed and the engine stopped, nothing appends to these.
        let samples = Array(microphone.audioSamples)
        microphone.purgeAudioSamples(keepingLast: 0)

        // Finished before the final pass begins, so the two are never on the
        // model at once and a late preview cannot overwrite the transcript.
        let preview = previewTask
        previewTask = nil
        preview?.cancel()
        await preview?.value
        guard dictation == ours else { return }

        // Silence, or a key pressed twice by accident. Whisper handed a fraction
        // of a second of nothing, or a minute of the room, does not return
        // nothing — it returns whatever its training data had in the quiet parts,
        // which is how a subtitle credit ends up in somebody's document.
        guard samples.count > Self.sampleRate / 2, Self.containsSpeech(samples) else {
            volatileTail = ""
            yieldUpdate()
            finish(throwing: nil)
            return
        }

        // In a task of its own so that `cancel()` can stop it partway.
        let pass = Task { try await self.finalTranscript(of: samples) }
        finalPass = pass
        let outcome = await pass.result
        // Cancelled or overtaken while it ran, and whoever did that has already
        // closed the stream.
        guard dictation == ours else { return }
        finalPass = nil

        switch outcome {
        case .success(let text):
            // The one pass that counts, over the whole recording. Whatever the
            // previews said is replaced rather than added to — and if all of it
            // was filtered out, the dictation is empty rather than made up.
            settled = text
            volatileTail = ""
            yieldUpdate()
            finish(throwing: nil)
        case .failure(let error):
            finish(throwing: error)
            throw error
        }
    }

    private func finalTranscript(of samples: [Float]) async throws -> String {
        let pipeline = try await loadedPipeline()
        do {
            return try await transcribe(samples, with: pipeline)
        } catch {
            throw TranscriptionFailure.underlying(String(describing: error))
        }
    }

    public func cancel() async {
        dictation += 1
        recording = false
        previewTask?.cancel()
        previewTask = nil
        finalPass?.cancel()
        finalPass = nil
        microphone.stopRecording()
        microphone.purgeAudioSamples(keepingLast: 0)
        live = nil
        finish(throwing: nil)
    }

    // MARK: - Loading

    private func loadedPipeline() async throws -> WhisperKit {
        while true {
            let model = requestedModel
            if let pipeline, loadedVariant == model.variant {
                return pipeline
            }

            if loadingVariant == nil {
                guard catalogue.state(of: model) == .installed else {
                    throw TranscriptionFailure.modelNotInstalled(model.label)
                }
                loadingVariant = model.variant
                // Not tied to the caller's task: a preview cancelled by `stop()`
                // must not take down the load that `stop()` is about to wait for.
                Task { await self.load(model) }
            }

            // Woken when the load in flight ends, which need not be with the model
            // wanted now — the choice can change while it runs — so round again.
            try await withCheckedThrowingContinuation { loadWaiters.append($0) }
        }
    }

    private func load(_ model: WhisperModel) async {
        var failure: (any Error)?
        do {
            let built = try await WhisperKit(WhisperKitConfig(
                model: model.variant,
                downloadBase: catalogue.downloadBase,
                modelRepo: WhisperModelCatalogue.repository,
                // Named explicitly, because `download: false` with no folder
                // means WhisperKit never establishes where the weights are and
                // fails having looked nowhere.
                modelFolder: catalogue.folder(for: model).filePath,
                tokenizerFolder: catalogue.downloadBase,
                // No `audioProcessor`: the microphone stays ours alone. A
                // WhisperKit stops its processor when it is released, so a
                // pipeline replaced mid-dictation would end the recording.
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                // Fetching is the catalogue's job, and it is a job with a
                // progress bar. A pipeline that quietly downloads six hundred
                // megabytes because somebody pressed a hotkey is not one.
                download: false))
            // Kept only if it is still the model wanted. One chosen while this
            // loaded is what the waiters will go round again for.
            if requestedModel.variant == model.variant {
                pipeline = built
                loadedVariant = model.variant
            }
        } catch {
            failure = TranscriptionFailure.underlying(
                "\(model.label) yüklenemedi: \(error)")
        }

        loadingVariant = nil
        let waiters = loadWaiters
        loadWaiters = []
        let stillWanted = requestedModel.variant == model.variant
        for waiter in waiters {
            if let failure, stillWanted {
                waiter.resume(throwing: failure)
            } else {
                waiter.resume()
            }
        }
    }
}

/// The last thirty seconds of the dictation, behind a lock. The processor's own
/// `audioSamples` grows on the audio thread unguarded, so the preview and the
/// meter read this copy, filled from its callback, instead.
final class LiveRecording: Sendable {
    private struct Contents {
        var recent: [Float] = []
        var count = 0
        var level: Float = 0
    }

    private let contents = Mutex(Contents())
    private let window: Int

    /// The quietest level a meter shows anything for, in dBFS.
    static let meterFloor: Float = -50
    /// The level a meter shows as full, in dBFS. A voice at dictation distance
    /// peaks around here, so a meter that only fills for shouting reads as dead.
    static let meterCeiling: Float = -10
    /// How much of the previous level survives each buffer, which is a tenth
    /// of a second: high enough that the meter falls rather than flickers.
    static let meterDecay: Float = 0.7

    init(window: Int) {
        self.window = window
    }

    func append(_ samples: [Float]) {
        let level = Self.level(ofRMS: AudioProcessor.calculateAverageEnergy(of: samples))
        contents.withLock { contents in
            contents.recent.append(contentsOf: samples)
            // Trimmed a window at a time rather than every buffer, so the copy
            // is paid once every thirty seconds instead of ten times a second.
            if contents.recent.count > 2 * window {
                contents.recent.removeFirst(contents.recent.count - window)
            }
            contents.count += samples.count
            contents.level = max(level, contents.level * Self.meterDecay)
        }
    }

    var recentSamples: [Float] {
        contents.withLock { Array($0.recent.suffix(window)) }
    }

    var sampleCount: Int { contents.withLock { $0.count } }

    var level: Float { contents.withLock { $0.level } }

    /// An RMS level as a meter reading: 0 at `meterFloor` and below, 1 at
    /// `meterCeiling` and above, in proportion to the decibels in between.
    static func level(ofRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - meterFloor) / (meterCeiling - meterFloor)))
    }
}
