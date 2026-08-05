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
        self.hotkeys = CarbonHotkeyMonitor()

        let runner = ClaudeAgentRunner(model: initial.agentModel)
        self.agentRunner = runner
        self.conversation = AgentConversation(runner: runner)

        self.session = DictationSession(
            transcriber: transcriber,
            refiner: ClaudeRefiner(
                model: initial.agentModel ?? "haiku",
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
        await refreshPermissions()
        await refreshAgentAvailability()
        await refreshLocales()

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
                state = newState
            case .notice(let message):
                notice = message
            case .agentPrompt(let prompt):
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

    func update(_ change: @escaping @Sendable (inout Settings) -> Void) {
        Task {
            do {
                try await settingsService.update(change)
                settingsProblem = nil
            } catch {
                settingsProblem = String(describing: error)
            }
            let updated = await settingsService.settings
            let languageChanged = updated.language != settings.language
            let keysChanged = updated.bindings != settings.bindings
            settings = updated

            if languageChanged {
                await transcriber.use(locale: updated.language.map(Locale.init(identifier:)))
            }
            if keysChanged {
                registerShortcuts()
            }
        }
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
            // Carbon calls this on the main thread, but the port promises
            // nothing, so the hop is explicit.
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch action {
                case .toggle: self.toggle()
                case .cancel: self.cancel()
                case .agent: self.askAgent()
                }
            }
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

    func request(_ kind: PermissionKind) async {
        await permissionAuthority.request(kind)
        await refreshPermissions()
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
    }

    func installModel(for locale: Locale) async {
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

    /// Whether the language the user has chosen can actually be transcribed.
    var languageNeedsAModel: Bool {
        let wanted = settings.language.map(Locale.init(identifier:)) ?? Locale.current
        guard !installedLocales.isEmpty else { return false }   // not yet known
        return !installedLocales.contains {
            $0.identifier(.bcp47) == wanted.identifier(.bcp47)
                || $0.language.languageCode == wanted.language.languageCode
        }
    }

    private func refreshAgentAvailability() async {
        agentAvailable = await agentRunner.isAvailable()
    }
}
