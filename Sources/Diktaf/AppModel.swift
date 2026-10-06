import AppKit
import DiktafClaude
import DiktafCore
import DiktafMac
import DiktafOllama
import DiktafWhisper
import Foundation
import Observation

/// The composition root, and the only place that decides which adapter fills
/// which port.
///
/// Also the one object the interface talks to. It holds no rules of its own: the
/// flow belongs to `DictationSession`, the prompt to `CleanupRuleSet`, the
/// conversation to `AgentConversation`. What is here is wiring, and the mirror of
/// the session's state that SwiftUI can observe.
@MainActor
@Observable
final class AppModel {
    // MARK: - What the interface watches

    private(set) var state: DictationState = .idle

    /// The last thing worth mentioning that was not a failure — a cleanup that
    /// timed out, say. Cleared when the user has seen it.
    private(set) var notice: String?

    private(set) var settings: Settings
    private(set) var settingsProblem: String?
    private(set) var permissions: [PermissionKind: PermissionState] = [:]

    /// Combinations the system refused because something else already holds them.
    private(set) var refusedShortcuts: [HotkeyBinding] = []

    private(set) var agentTurns: [AgentTurn] = []
    private(set) var agentIsThinking = false
    private(set) var agentAvailable = false

    /// Languages the recogniser has a model for, for the settings window.
    private(set) var installedLocales: [Locale] = []
    private(set) var supportedLocales: [Locale] = []
    private(set) var modelInstallation: (locale: Locale, progress: Progress)?

    /// Whether the chosen language can be dictated in. Nil until it is known,
    /// which is the difference between "no model" and "not asked yet".
    private(set) var languageState: SpeechModelCatalogue.ModelState?

    /// Whether the chosen Whisper model's weights are here. Nil until asked, for
    /// the same reason as `languageState`.
    private(set) var whisperState: WhisperModelCatalogue.ModelState?

    /// The download and the preparation that follows it, while either is
    /// happening. Two phases rather than one because only the first has a
    /// percentage.
    private(set) var whisperInstallation: WhisperModelCatalogue.InstallationPhase?

    // MARK: - What the indicator shows of the work behind each step

    /// The dictation in progress, step by step. Kept after it ends so the
    /// indicator can show how it went; replaced when the next one starts.
    private(set) var progress: DictationProgress?

    /// Who the current cleanup is waiting on, which is not always the engine in
    /// the settings: Claude stands in when Ollama cannot be reached.
    private(set) var cleanupChoice: EngineSwitchingRefiner.Choice?

    /// The most recent input levels, oldest first, for the meter.
    private(set) var inputLevels: [Float] = []
    private(set) var recordedSeconds: Double = 0
    private(set) var whisperLoadState: WhisperTranscriber.LoadState = .notLoaded

    /// Recording for a while with nothing above the noise floor.
    private(set) var hearsNothing = false

    /// When the speaker last went quiet, while that quiet may yet end the
    /// dictation by itself.
    private(set) var silenceSince: Date?

    /// Between the key press and the recogniser actually listening. A state of
    /// the interface rather than of the session: the session refuses a second
    /// press meanwhile, and all the indicator needs is to appear at once.
    private(set) var isStarting = false

    /// The application the text is headed for, noted at the key press.
    private(set) var deliveryTarget: String?

    /// How the last dictation ended, shown for a moment after it has.
    private(set) var outcome: DictationOutcome?

    /// Bumped to ask for the agent window; the menu bar label opens it, since
    /// only a view can.
    private(set) var agentWindowRequests = 0

    // MARK: - Ollama

    private(set) var ollamaRunning: Bool?
    private(set) var ollamaModels: [String] = []

    // MARK: - The pieces

    private let settingsService: SettingsService
    private let transcriber: EngineSwitchingTranscriber
    private let catalogue = SpeechModelCatalogue()
    private let whisperCatalogue = WhisperModelCatalogue()
    private let ollamaCatalogue = OllamaModelCatalogue()
    private var meter: Task<Void, Never>?
    private let cleanupChoices: AsyncStream<EngineSwitchingRefiner.Choice>
    private var outcomeExpiry: Task<Void, Never>?
    private let permissionAuthority: any PermissionAuthority
    private let hotkeys: any HotkeyMonitor
    private let session: DictationSession
    private let conversation: AgentConversation
    private let agentRunner: any AgentRunner

    init() {
        let storage = FileSettingsStorage.inUserConfiguration()
        let service = SettingsService(storage: storage)
        self.settingsService = service

        // Read once here rather than awaited, because the interface needs
        // something to draw before the first await completes. The service is the
        // authority from then on.
        let initial = Settings.defaults
        self.settings = initial

        let permissions = MacPermissions()
        self.permissionAuthority = permissions
        self.hotkeys = MacHotkeyMonitor()

        // Both recognisers are built whichever one is chosen. Neither costs
        // anything until it is started — the Whisper one does not touch its
        // weights, and the system one does not touch the microphone — and
        // building only the chosen one would mean rebuilding the session to
        // switch, which is the thing `EngineSwitchingTranscriber` exists to
        // avoid.
        let locale = initial.language.map(Locale.init(identifier:))
        let transcriber = EngineSwitchingTranscriber(
            engine: initial.engine,
            system: SystemTranscriber(locale: locale),
            whisper: WhisperTranscriber(
                model: WhisperModelCatalogue.model(named: initial.whisperModel),
                locale: locale,
                permissions: permissions))
        self.transcriber = transcriber

        // Both models are read from the settings at the moment they are used
        // rather than captured here. These two objects live for as long as the
        // application does, so a value read now is the value from before the user
        // changed it — which is indistinguishable from the setting doing nothing.
        let runner = ClaudeAgentRunner(model: { await service.settings.agentModel })
        self.agentRunner = runner
        self.conversation = AgentConversation(
            runner: runner,
            isSessionExpired: { ($0 as? AgentRunnerFailure) == .sessionExpired })

        // A stream rather than a callback into self, which does not exist yet.
        let (choiceStream, choices) = AsyncStream.makeStream(of: EngineSwitchingRefiner.Choice.self)
        self.cleanupChoices = choiceStream
        let refiner = EngineSwitchingRefiner(
            ollama: OllamaRefiner(
                model: { await service.settings.ollamaModel },
                timeoutSeconds: { await service.settings.refinerTimeoutSeconds }),
            claude: ClaudeRefiner(
                model: { await service.settings.cleanupModel },
                timeoutSeconds: { await service.settings.refinerTimeoutSeconds }),
            settings: { await service.settings },
            report: { choices.yield($0) })

        self.session = DictationSession(
            transcriber: transcriber,
            refiner: refiner,
            clipboard: PasteboardClipboard(),
            keyboard: CGEventKeyboard(),
            focus: AppKitFocusGuard(),
            settings: { await service.settings }
        )
    }

    /// Everything that has to happen after the object exists: reading the
    /// settings, registering the keys, watching the session.
    func start() async {
        settings = await settingsService.settings
        settingsProblem = await settingsService.loadFailure
        await transcriber.use(locale: settings.language.map(Locale.init(identifier:)))
        await transcriber.use(engine: settings.engine)
        await transcriber.use(whisperModel: chosenWhisperModel)

        registerShortcuts()

        // Not awaited. The prompt is a dialogue somebody has to answer, and
        // everything below — watching the session, reading the language list —
        // would otherwise sit behind it for as long as it stayed on screen.
        Task { await askForWhatHasNotBeenAsked() }

        await refreshPermissions()
        Diagnostics.event("permissions: " + PermissionKind.allCases
            .map { "\($0.rawValue)=\(permissions[$0]?.rawValue ?? "?")" }
            .joined(separator: " "))
        await refreshAgentAvailability()
        await catalogue.reserve(chosenLocale)
        await refreshLocales()
        Diagnostics.event(
            "language \(chosenLocale.identifier(.bcp47)): "
            + String(describing: languageState ?? .notInstalled))

        refreshWhisperState()
        Diagnostics.event("engine: \(settings.engine.rawValue), "
            + "\(chosenWhisperModel.variant) is "
            + String(describing: whisperState ?? .notInstalled))

        // Not awaited, and deliberately not reported. Whisper takes seconds to
        // get into memory the first time, and paid here it is paid while nobody
        // is holding a key down. A failure is the first dictation's to report:
        // this is an optimisation, and it is not the moment to tell somebody who
        // has not asked for anything that something went wrong.
        if settings.engine == .whisper, whisperState == .installed {
            Task { await prepareWhisper() }
        }

        Task { await watchSession() }
        Task {
            for await choice in cleanupChoices {
                Diagnostics.event("cleanup by \(choice.engine.rawValue) \(choice.model)"
                    + (choice.fallbackReason.map { ", standing in: \($0)" } ?? ""))
                cleanupChoice = choice
            }
        }

        await refreshOllama()
        if settings.cleanupEnabled, settings.cleanupEngine == .ollama, ollamaRunning == true {
            Task { await prepareOllama() }
        }
    }

    // MARK: - The two verbs, as the interface calls them

    func toggle() {
        start(destination: .insertion)
    }

    func askAgent() {
        guard settings.agentEnabled else { return }
        start(destination: .agent)
    }

    /// Both verbs, since a press means "stop" while recording and "start"
    /// otherwise — and only a start has anything to set up here.
    private func start(destination: DictationDestination) {
        notice = nil
        guard !isStarting else { return }
        if !state.isBusy {
            isStarting = true
            outcome = nil
            outcomeExpiry?.cancel()
            cleanupChoice = nil
            progress = nil
            deliveryTarget = NSWorkspace.shared.frontmostApplication
                .flatMap { $0 == NSRunningApplication.current ? nil : $0.localizedName }
            // The model is loaded while the user talks, so the cleanup that
            // follows does not start with a cold load.
            if destination == .insertion, settings.cleanupEnabled,
               settings.cleanupEngine == .ollama {
                Task { await prepareOllama() }
            }
        }
        Task { await session.toggle(destination: destination) }
    }

    func cancel() {
        if state.isBusy || isStarting { cancelledByUser = true }
        isStarting = false
        Task { await session.cancel() }
    }

    private var cancelledByUser = false

    func dismissNotice() {
        notice = nil
    }

    func dismissOutcome() {
        outcomeExpiry?.cancel()
        outcome = nil
    }

    // MARK: - Watching the session

    private func watchSession() async {
        for await event in await session.events() {
            switch event {
            case .state(let newState):
                Diagnostics.state(newState.logDescription)
                if case .failed(let message) = newState { Diagnostics.failure(message) }
                let previous = state
                state = newState
                isStarting = false
                followMeter()
                // Idle after idle is the first event of the stream, not an ending.
                if !newState.isBusy, previous.isBusy || newState != .idle {
                    concludeDictation(endingIn: newState)
                }
            case .notice(let message):
                Diagnostics.event("notice: \(message)")
                notice = message
            case .agentPrompt(let prompt):
                Diagnostics.event("agent asked: \(prompt.count) characters")
                // Not awaited: an agent turn can take minutes, and the loop has
                // to keep reading the session's states meanwhile.
                agentWindowRequests += 1
                let previous = pendingQuestions
                pendingQuestions = Task {
                    await previous?.value
                    await ask(prompt)
                }
            case .progress(let newProgress):
                Diagnostics.event(newProgress.logDescription)
                progress = newProgress
            }
        }
    }

    /// Questions asked while the agent is still answering one wait their turn,
    /// so that each is a turn of the same conversation rather than a fork of it.
    private var pendingQuestions: Task<Void, Never>?

    private func ask(_ prompt: String) async {
        agentIsThinking = true
        defer { agentIsThinking = false }
        do {
            _ = try await conversation.ask(prompt)
        } catch {
            notice = Self.message(for: error)
        }
        agentTurns = await conversation.turns
    }

    // MARK: - How a dictation ended

    /// What the indicator says once the work is done, and for how long.
    ///
    /// The session goes straight to idle when the text has arrived, which is
    /// right for the session and too quick for a person: an indicator that
    /// vanishes the moment it finishes looks the same as one that gave up.
    private func concludeDictation(endingIn newState: DictationState) {
        let concluded: DictationOutcome?
        if case .failed(let message) = newState {
            concluded = .failed(message)
        } else if cancelledByUser {
            concluded = .cancelled
        } else if let progress, progress.deliveredAt != nil {
            concluded = .delivered(progress, target: deliveryTarget)
        } else if let progress, progress.destination == .agent,
                  progress.rawTranscript?.isEmpty == false {
            concluded = .askedAgent
        } else if let progress, progress.transcriptReadyAt != nil {
            concluded = .nothingHeard
        } else {
            concluded = nil
        }
        cancelledByUser = false
        guard let concluded else { return }

        outcome = concluded
        outcomeExpiry?.cancel()
        let shownFor = concluded.shownFor(withNotice: notice != nil)
        outcomeExpiry = Task { [weak self] in
            try? await Task.sleep(for: shownFor)
            guard !Task.isCancelled else { return }
            self?.outcome = nil
        }
    }

    // MARK: - The meter

    /// Polls the recogniser's level while recording.
    ///
    /// Polled rather than streamed because the level is not part of the
    /// `Transcriber` port and should not be: it is the interface asking the
    /// adapter in use, the way `prepareWhisper` is.
    private func followMeter() {
        let listening = if case .recording = state { true } else { false }
        guard listening else {
            meter?.cancel()
            meter = nil
            return
        }
        guard meter == nil else { return }
        inputLevels = []
        recordedSeconds = 0
        hearsNothing = false
        silenceSince = nil
        meter = Task { [weak self, transcriber] in
            var silence = SilenceDetector()
            var stopped = false
            while !Task.isCancelled {
                let level = await transcriber.inputLevel()
                let seconds = await transcriber.recordedSeconds()
                let load = await transcriber.whisperLoadState()
                guard let self, !Task.isCancelled else { return }
                self.inputLevels = Array((self.inputLevels + [level]).suffix(Self.meterLength))
                self.recordedSeconds = seconds
                // Only on change: the indicator resizes on these, and an
                // observed property that is set twenty times a second redraws
                // the panel twenty times a second whether or not it changed.
                if self.whisperLoadState != load { self.whisperLoadState = load }
                let silent = seconds > 2.5 && (self.inputLevels.max() ?? 0) < 0.04
                if self.hearsNothing != silent { self.hearsNothing = silent }

                let now = Date()
                silence.observe(level: level, at: now)
                if self.silenceSince != silence.quietSince { self.silenceSince = silence.quietSince }
                if !stopped, self.settings.silenceStopEnabled,
                   let quiet = silence.quiet(at: now), quiet >= self.silenceStopDelay {
                    stopped = true
                    Diagnostics.event(String(format: "stopping after %.1fs of quiet", quiet))
                    self.finishOnSilence()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static let meterLength = 32

    /// The setting, held to something a person could mean: under a second
    /// ends a sentence at its first comma.
    var silenceStopDelay: TimeInterval {
        min(15, max(1, settings.silenceStopSeconds))
    }

    /// The same as pressing the key again, which is what the user would have
    /// done.
    private func finishOnSilence() {
        guard case .recording(_, let destination) = state else { return }
        Task { await session.toggle(destination: destination) }
    }

    func clearConversation() {
        Task {
            await conversation.clear()
            agentTurns = await conversation.turns
        }
    }

    // MARK: - Settings

    /// Applies a change here first, then stores it.
    ///
    /// The order matters to every control in the settings window. Storing is
    /// asynchronous, so a view that redraws from the stored value between the
    /// click and the write shows the old one — a picker that springs back, a
    /// field that will not take a character. Applied on this side first, the
    /// interface always shows what the user just chose, and the store catches up.
    func update(_ change: @escaping @Sendable (inout Settings) -> Void) {
        let previous = settings
        var draft = settings
        change(&draft)
        guard draft != previous else { return }
        settings = draft
        apply(draft, over: previous)

        Task {
            do {
                try await settingsService.update(change)
                settingsProblem = nil
            } catch {
                settingsProblem = Self.message(for: error)
            }
        }
    }

    /// Whatever changing from one set of settings to the other has to reach
    /// beyond the settings themselves.
    private func apply(_ draft: Settings, over previous: Settings) {
        if draft.language != previous.language {
            Task { await applyLanguage(draft.language) }
        }
        if draft.engine != previous.engine {
            Task { await applyEngine(draft.engine) }
        }
        if draft.whisperModel != previous.whisperModel {
            Task { await applyWhisperModel() }
        }
        // The agent key is registered only while the agent is on, so turning
        // it on or off is a change of bindings too.
        if draft.bindings != previous.bindings || draft.agentEnabled != previous.agentEnabled {
            registerShortcuts()
        }
        if draft.cleanupEngine != previous.cleanupEngine || draft.ollamaModel != previous.ollamaModel,
           draft.cleanupEngine == .ollama {
            Task {
                await refreshOllama()
                await prepareOllama()
            }
        }
    }

    private func applyLanguage(_ identifier: String?) async {
        await transcriber.use(locale: identifier.map(Locale.init(identifier:)))

        // Choosing a language is the moment to claim it. A model that is on disk
        // but not reserved by this application does not count as installed, and
        // reserving it after a dictation has started — which is where this used
        // to happen — is too late, because the dictation cannot start.
        await catalogue.reserve(chosenLocale)

        await refreshLocales()
        Diagnostics.event(
            "language \(chosenLocale.identifier(.bcp47)): "
            + String(describing: languageState ?? .notInstalled))
    }

    private func applyEngine(_ engine: TranscriptionEngine) async {
        await transcriber.use(engine: engine)
        refreshWhisperState()
        Diagnostics.event("engine is now \(engine.rawValue)")

        // Choosing Whisper is the moment to get it into memory: somebody who has
        // just picked it is likely to try it, and the alternative is that the
        // first dictation after the choice is the slow one.
        if engine == .whisper, whisperState == .installed {
            Task { await prepareWhisper() }
        }
    }

    private func applyWhisperModel() async {
        await transcriber.use(whisperModel: chosenWhisperModel)
        refreshWhisperState()
        Diagnostics.event("whisper model is now \(chosenWhisperModel.variant)")
        if settings.engine == .whisper, whisperState == .installed {
            Task { await prepareWhisper() }
        }
    }

    func resetSettings() {
        Task {
            let previous = settings
            do {
                try await settingsService.reset()
                settingsProblem = nil
            } catch {
                settingsProblem = Self.message(for: error)
            }
            settings = await settingsService.settings
            // Through the same path as a change, or the recogniser and the keys
            // carry on with the settings from before the reset.
            apply(settings, over: previous)
        }
    }

    // MARK: - Shortcuts

    private func registerShortcuts() {
        let wanted = settings.bindings.filter { binding in
            // The agent key is not registered while the feature is off, so that
            // the combination is free for whatever else wants it.
            binding.action != .agent || settings.agentEnabled
        }
        refusedShortcuts = hotkeys.rebind(wanted) { [weak self] action in
            // The monitor promises nothing about which thread this arrives on.
            Task { @MainActor in
                guard let model = self else {
                    // Only reachable if the model outlives its owner, which is
                    // what a `@State` read in `App.init` used to cause: the keys
                    // fired into an object that had already gone.
                    Diagnostics.failure("hotkey \(action) arrived with no model")
                    return
                }
                Diagnostics.event("hotkey: \(action)")
                switch action {
                case .toggle: model.toggle()
                case .cancel: model.cancel()
                case .agent: model.askAgent()
                }
            }
        }
        for binding in refusedShortcuts {
            Diagnostics.failure(
                "\(binding.combination.displayName) was refused; something else holds it")
        }
    }

    // MARK: - Permissions

    func refreshPermissions() async {
        var found: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases {
            found[kind] = await permissionAuthority.state(of: kind)
        }
        permissions = found
    }

    /// Puts the microphone prompt up at startup rather than at the first
    /// dictation.
    ///
    /// The prompt is a dialogue somebody has to answer, and answering it takes
    /// as long as it takes. Asked at the moment the key is pressed, the dictation
    /// sits there waiting on it and looks broken — which is the same thing the
    /// user would have seen from the bug this replaced. Asked at launch, the
    /// question arrives when nothing is waiting on the answer.
    ///
    /// Only what has never been asked: a permission already refused is not asked
    /// again, because macOS would not show the prompt anyway.
    private func askForWhatHasNotBeenAsked() async {
        for kind in [PermissionKind.microphone, .speechRecognition] {
            if await permissionAuthority.state(of: kind) == .undetermined {
                Diagnostics.event("asking for \(kind.rawValue)")
                await permissionAuthority.request(kind)
                Diagnostics.event(
                    "\(kind.rawValue) answered: "
                    + (await permissionAuthority.state(of: kind)).rawValue)
            }
        }
        await refreshPermissions()
    }

    func request(_ kind: PermissionKind) async {
        await permissionAuthority.request(kind)
        await refreshPermissions()
        Diagnostics.event("permission \(kind.rawValue) is now \(permissions[kind]?.rawValue ?? "?")")
    }

    func openSettings(for kind: PermissionKind) {
        permissionAuthority.openSettings(for: kind)
    }

    /// The permissions that stand between the user and a dictation that works.
    ///
    /// Keyboard control is included even though nothing fails without it,
    /// because what happens instead is worse: macOS reports the paste as having
    /// happened and the text arrives nowhere.
    var missingPermissions: [PermissionKind] {
        PermissionKind.allCases.filter { kind in
            guard settings.delivery != .clipboardOnly || kind != .keyboardControl else {
                return false
            }
            return permissions[kind] != .granted
        }
    }

    // MARK: - Speech models

    func refreshLocales() async {
        installedLocales = await catalogue.installedLocales()
        supportedLocales = await catalogue.supportedLocales()
        await refreshLanguageState()
    }

    func installModel(for locale: Locale) async {
        Diagnostics.event("installing the speech model for \(locale.identifier(.bcp47))")
        do {
            try await catalogue.install(locale) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.modelInstallation = (locale, progress)
                }
            }
            modelInstallation = nil
            await refreshLocales()
        } catch {
            modelInstallation = nil
            notice = Self.message(for: error)
        }
    }

    /// Whether the language the user has chosen can be transcribed now, later, or
    /// not at all.
    ///
    /// Asked of the catalogue rather than worked out from `installedLocales`
    /// here. Two places deciding the same thing is how they come to disagree, and
    /// the catalogue is the one that knows what the framework means by it.
    func refreshLanguageState() async {
        languageState = await catalogue.state(of: chosenLocale)
    }

    /// The locale a dictation would actually use.
    var chosenLocale: Locale {
        settings.language.map(Locale.init(identifier:)) ?? Locale.current
    }

    /// The languages to offer, in an order a person can find one in.
    ///
    /// Sorted by the name they are shown under rather than left in the order the
    /// framework returns them, and marked where the model is already on disk —
    /// which is the difference between picking a language and picking a download.
    var languageChoices: [LanguageChoice] {
        let installed = Set(installedLocales.map { $0.identifier(.bcp47) })
        return supportedLocales
            .map { locale in
                let identifier = locale.identifier(.bcp47)
                return LanguageChoice(
                    identifier: identifier,
                    label: installed.contains(identifier)
                        ? "✓ \(locale.readableName)"
                        : locale.readableName
                )
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    struct LanguageChoice: Identifiable, Hashable {
        let identifier: String
        let label: String
        var id: String { identifier }
    }

    private func refreshAgentAvailability() async {
        agentAvailable = await agentRunner.isAvailable()
    }

    // MARK: - Whisper

    /// The Whisper model the settings point at.
    var chosenWhisperModel: WhisperModel {
        WhisperModelCatalogue.model(named: settings.whisperModel)
    }

    /// What the picker offers, plus whatever is in the settings if it is not on
    /// the list — the same courtesy the model pickers extend to a name typed by
    /// hand.
    var whisperChoices: [WhisperModel] {
        let offered = WhisperModelCatalogue.choices
        let chosen = chosenWhisperModel
        guard !offered.contains(where: { $0.variant == chosen.variant }) else { return offered }
        return offered + [chosen]
    }

    /// Whether the weights are on disk. Synchronous because it is a question
    /// about the file system and nothing else, and a settings row that has to
    /// wait for an answer flickers.
    func refreshWhisperState() {
        whisperState = whisperCatalogue.state(of: chosenWhisperModel)
    }

    private func prepareWhisper() async {
        do {
            try await transcriber.prepareWhisper()
            Diagnostics.event("whisper is loaded and ready")
        } catch {
            Diagnostics.failure("whisper could not be preloaded: \(error)")
        }
    }

    /// Fetches the chosen model's weights and gets it ready to dictate with.
    func installWhisperModel() async {
        let model = chosenWhisperModel
        guard whisperInstallation == nil else { return }
        Diagnostics.event("installing whisper \(model.variant), \(model.megabytes) MB")

        whisperInstallation = .downloading(Progress())
        do {
            try await whisperCatalogue.install(model) { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.whisperInstallation = phase
                }
            }
            whisperInstallation = nil
            refreshWhisperState()
            Diagnostics.event("whisper \(model.variant) is installed")

            // Already loaded by the installation, so this only claims it for the
            // transcriber rather than paying for a second load.
            if settings.engine == .whisper { await prepareWhisper() }
        } catch {
            whisperInstallation = nil
            refreshWhisperState()
            notice = Self.message(for: error)
        }
    }

    /// Deletes the chosen model's weights.
    ///
    /// Offered because these are the largest files Diktaf will ever put on
    /// somebody's disk, and an engine you can switch away from but not reclaim
    /// the space from is a poor bargain.
    func removeWhisperModel() {
        let model = chosenWhisperModel
        do {
            let reclaimed = try whisperCatalogue.remove(model)
            refreshWhisperState()
            let readable = ByteCountFormatStyle(style: .file).format(reclaimed)
            notice = "\(model.label) kaldırıldı, \(readable) yer açıldı."
            Diagnostics.event("removed whisper \(model.variant), \(reclaimed) bytes")
        } catch {
            notice = Self.message(for: error)
        }
    }

    /// Whether a dictation would fail right now for want of a model.
    ///
    /// Asked by the menu bar as well as the settings window, because the failure
    /// it prevents — press the key, talk, get nothing — is the one worth warning
    /// about before it happens rather than explaining afterwards.
    var engineNeedsDownload: Bool {
        switch settings.engine {
        case .system: languageState == .notInstalled
        case .whisper: whisperState == .notInstalled
        }
    }
}

// MARK: - Ollama

extension AppModel {
    /// The model cleanup would ask Ollama for.
    var chosenOllamaModel: String {
        OllamaModelCatalogue.model(named: settings.ollamaModel)
    }

    /// What Ollama has, plus the chosen one if it has not been pulled — shown
    /// rather than dropped, so a name set by hand is not silently replaced.
    var ollamaChoices: [String] {
        let chosen = chosenOllamaModel
        return ollamaModels.contains(chosen) ? ollamaModels : ollamaModels + [chosen]
    }

    /// Whether cleanup with Ollama would work right now, for the settings row.
    var ollamaHasChosenModel: Bool {
        ollamaModels.contains(chosenOllamaModel)
    }

    func refreshOllama() async {
        let running = await ollamaCatalogue.isRunning()
        ollamaRunning = running
        ollamaModels = running ? await ollamaCatalogue.installedModels() : []
        Diagnostics.event("ollama: " + (running
            ? "running, \(ollamaModels.count) models, \(chosenOllamaModel) "
              + (ollamaHasChosenModel ? "is there" : "is missing")
            : "not running"))
    }

    /// Loads the model into memory, or keeps it there. Cheap when it already
    /// is, so it is asked at every dictation rather than tracked.
    func prepareOllama() async {
        await ollamaCatalogue.prepare(model: settings.ollamaModel)
    }
}

// MARK: - Messages

extension AppModel {
    /// A failure in words for the person reading the menu, rather than an enum.
    static func message(for error: any Error) -> String {
        switch error {
        case AgentRunnerFailure.sessionExpired:
            "Agent konuşması artık yok; yeni bir konuşma başlatın."
        case SettingsServiceError.unreadableFile(let detail):
            "Ayar dosyası okunamadı, bu yüzden değişiklikler kaydedilmiyor. "
            + "Ayarları sıfırlayınca yeni bir dosya yazılır. (\(detail))"
        default:
            DictationSession.describe(error)
        }
    }
}

/// How a dictation ended, for the indicator to say before it goes.
enum DictationOutcome: Equatable {
    case delivered(DictationProgress, target: String?)
    case askedAgent
    case nothingHeard
    case cancelled
    case failed(String)

    /// Long enough to be read, and a failure longer: that one is a message
    /// somebody has to act on.
    func shownFor(withNotice: Bool) -> Duration {
        switch self {
        case .delivered: withNotice ? .seconds(5) : .seconds(2.5)
        case .askedAgent, .nothingHeard: .seconds(2)
        case .cancelled: .seconds(1.2)
        case .failed: .seconds(7)
        }
    }
}

// MARK: - The log

extension DictationState {
    /// The state without the words in it. The log is plain text on disk, and
    /// what somebody dictated is not something to leave lying there.
    var logDescription: String {
        switch self {
        case .recording(let text, let destination):
            "recording(\(text.count) characters, \(destination.rawValue))"
        case .failed: "failed"
        default: String(describing: self)
        }
    }
}

extension DictationProgress {
    /// Where the dictation has got to and how long each step took, without
    /// the transcript.
    var logDescription: String {
        var parts = ["progress: \(destination.rawValue)"]
        if let ended = recordingEndedAt {
            parts.append(String(format: "recorded %.1fs", ended.timeIntervalSince(startedAt)))
        }
        if let ready = transcriptReadyAt, let ended = recordingEndedAt {
            parts.append(String(format: "transcribed in %.1fs, %d characters",
                                ready.timeIntervalSince(ended), rawTranscript?.count ?? 0))
        }
        if let cleanup {
            switch cleanup.outcome {
            case .running:
                parts.append("cleaning up with \(cleanup.engine.rawValue)")
            case .cleaned(_, let finished):
                parts.append(String(format: "cleaned up by %@ in %.1fs", cleanup.engine.rawValue,
                                    finished.timeIntervalSince(cleanup.startedAt)))
            case .fellBack(_, let finished):
                parts.append(String(format: "cleanup fell back after %.1fs",
                                    finished.timeIntervalSince(cleanup.startedAt)))
            case .skipped(let reason):
                parts.append("cleanup skipped: \(reason.rawValue)")
            }
        }
        if let delivery, let delivered = deliveredAt {
            parts.append(String(format: "%@ after %.1fs in all", delivery.rawValue,
                                delivered.timeIntervalSince(startedAt)))
        }
        return parts.joined(separator: ", ")
    }
}
