import DiktafClaude
import DiktafCore
import DiktafMac
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

    // MARK: - The pieces

    private let settingsService: SettingsService
    private let transcriber: SystemTranscriber
    private let catalogue = SpeechModelCatalogue()
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

        let transcriber = SystemTranscriber(locale: initial.language.map(Locale.init(identifier:)))
        self.transcriber = transcriber
        self.permissionAuthority = MacPermissions()
        self.hotkeys = MacHotkeyMonitor()

        // Both models are read from the settings at the moment they are used
        // rather than captured here. These two objects live for as long as the
        // application does, so a value read now is the value from before the user
        // changed it — which is indistinguishable from the setting doing nothing.
        let runner = ClaudeAgentRunner(model: { await service.settings.agentModel })
        self.agentRunner = runner
        self.conversation = AgentConversation(runner: runner)

        self.session = DictationSession(
            transcriber: transcriber,
            refiner: ClaudeRefiner(
                model: { await service.settings.cleanupModel },
                timeoutSeconds: initial.refinerTimeoutSeconds),
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

        Task { await watchSession() }
    }

    // MARK: - The two verbs, as the interface calls them

    func toggle() {
        notice = nil
        Task { await session.toggle(destination: .insertion) }
    }

    func askAgent() {
        guard settings.agentEnabled else { return }
        notice = nil
        Task { await session.toggle(destination: .agent) }
    }

    func cancel() {
        Task { await session.cancel() }
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: - Watching the session

    private func watchSession() async {
        for await event in await session.events() {
            switch event {
            case .state(let newState):
                Diagnostics.state(String(describing: newState))
                if case .failed(let message) = newState { Diagnostics.failure(message) }
                state = newState
            case .notice(let message):
                Diagnostics.event("notice: \(message)")
                notice = message
            case .agentPrompt(let prompt):
                Diagnostics.event("agent asked: \(prompt.count) characters")
                await ask(prompt)
            }
        }
    }

    private func ask(_ prompt: String) async {
        agentIsThinking = true
        defer { agentIsThinking = false }
        do {
            _ = try await conversation.ask(prompt)
        } catch AgentRunnerFailure.sessionExpired {
            // The conversation is gone rather than broken, so the question is
            // worth asking again as a new one instead of reporting a failure the
            // user can do nothing about.
            await conversation.startOver()
            _ = try? await conversation.ask(prompt)
        } catch {
            notice = String(describing: error)
        }
        agentTurns = await conversation.turns
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

        if draft.language != previous.language {
            Task { await applyLanguage(draft.language) }
        }
        if draft.bindings != previous.bindings {
            registerShortcuts()
        }

        Task {
            do {
                try await settingsService.update(change)
                settingsProblem = nil
            } catch {
                settingsProblem = String(describing: error)
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

    func resetSettings() {
        Task {
            try? await settingsService.reset()
            settings = await settingsService.settings
            registerShortcuts()
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
            notice = String(describing: error)
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
}
