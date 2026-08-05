import DiktafCore
import SwiftUI

struct SettingsWindow: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralTab(model: model)
            }
            Tab("Cleanup", systemImage: "wand.and.sparkles") {
                CleanupTab(model: model)
            }
            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsTab(model: model)
            }
            Tab("Agent", systemImage: "bubble.left.and.text.bubble.right") {
                AgentTab(model: model)
            }
        }
        .task { await model.refreshPermissions() }
        .task { await model.refreshLocales() }
        .safeAreaInset(edge: .bottom) {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
            }
        }
    }
}

// MARK: -

private struct GeneralTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Language") {
                Picker("Dictate in", selection: languageBinding) {
                    Text("Follow the system").tag(String?.none)
                    ForEach(model.supportedLocales, id: \.identifier) { locale in
                        Text(locale.localizedString ?? locale.identifier)
                            .tag(String?.some(locale.identifier(.bcp47)))
                    }
                }

                if model.languageNeedsAModel {
                    // Said plainly rather than left to fail at the first
                    // dictation, because the download takes minutes and a
                    // dictation that silently waits for one looks broken.
                    LabeledContent("Speech model") {
                        if let installing = model.modelInstallation {
                            ProgressView(installing.progress)
                                .progressViewStyle(.linear)
                        } else {
                            Button("Download") {
                                Task {
                                    await model.installModel(
                                        for: model.settings.language
                                            .map(Locale.init(identifier:)) ?? .current)
                                }
                            }
                        }
                    }
                }
            }

            Section("Where the text goes") {
                Picker("Deliver by", selection: deliveryBinding) {
                    Text("Pasting").tag(DeliveryMode.paste)
                    Text("Typing it out").tag(DeliveryMode.type)
                    Text("Leaving it on the clipboard").tag(DeliveryMode.clipboardOnly)
                }
                Text(deliveryExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Indicator") {
                Toggle("Show it while recording", isOn: overlayBinding)
            }

            Section("Permissions") {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    LabeledContent(kind.settingsLabel) {
                        PermissionRow(model: model, kind: kind)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var deliveryExplanation: String {
        switch model.settings.delivery {
        case .paste:
            "Fast, and what you want almost always. It uses the clipboard."
        case .type:
            "Slower, but it leaves your clipboard alone and works where pasting is refused."
        case .clipboardOnly:
            "Nothing is pressed on your behalf, so no accessibility permission is needed."
        }
    }

    private var languageBinding: Binding<String?> {
        Binding(get: { model.settings.language },
                set: { value in model.update { $0.language = value } })
    }

    private var deliveryBinding: Binding<DeliveryMode> {
        Binding(get: { model.settings.delivery },
                set: { value in model.update { $0.delivery = value } })
    }

    private var overlayBinding: Binding<Bool> {
        Binding(get: { model.settings.showOverlay },
                set: { value in model.update { $0.showOverlay = value } })
    }
}

private struct PermissionRow: View {
    let model: AppModel
    let kind: PermissionKind

    var body: some View {
        switch model.permissions[kind] ?? .undetermined {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .undetermined:
            Button("Ask") { Task { await model.request(kind) } }
        case .denied:
            // Asking again achieves nothing once the answer was no; the pane is
            // the only route left.
            Button("Open System Settings") { model.openSettings(for: kind) }
        }
    }
}

// MARK: -

private struct CleanupTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Clean up what I dictate", isOn: enabledBinding)
                Text("""
                What macOS heard goes to the claude command on this Mac to have \
                the rules below applied to it, and the result is what gets \
                pasted. It does not do the transcription — that is Apple's \
                recogniser, and it happens either way. Switch this off and the \
                raw transcript is pasted as it came. If it fails or takes too \
                long, that is what happens anyway.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ModelPicker(title: "Clean up with", selection: model.settings.cleanupModel) {
                    chosen in model.update { $0.cleanupModel = chosen }
                }
            } footer: {
                Text("""
                This runs on every dictation, so it is worth being fast. The \
                smallest model is a second or two quicker than the largest and \
                does this job perfectly well.
                """)
                .font(.caption)
            }

            Section("Rules") {
                ForEach(model.settings.rules.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
                Button("Add a rule", systemImage: "plus") {
                    model.update { $0.rules.rules.append(CleanupRule(text: "")) }
                }
            }

            Section("Anything else") {
                CommittingTextField(
                    placeholder: "Anything the rules above do not cover",
                    value: model.settings.rules.extraInstruction ?? "",
                    axis: .vertical
                ) { edited in
                    let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.update { $0.rules.extraInstruction = trimmed.isEmpty ? nil : trimmed }
                }
                .lineLimit(3...)
                Text("Free-form. A name it keeps mishearing, a house style, a word to avoid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Give up after") {
                    Stepper(
                        "\(model.settings.refinerTimeoutSeconds)s",
                        value: timeoutBinding, in: 3...120, step: 1)
                }
                Button("Put the recommended rules back") {
                    model.update { $0.rules = .recommended }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.settings.cleanupEnabled },
                set: { value in model.update { $0.cleanupEnabled = value } })
    }

    private var timeoutBinding: Binding<Int> {
        Binding(get: { model.settings.refinerTimeoutSeconds },
                set: { value in model.update { $0.refinerTimeoutSeconds = value } })
    }
}

private struct RuleRow: View {
    let model: AppModel
    let rule: CleanupRule

    var body: some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { value in
                    model.update { settings in
                        guard let index = settings.rules.rules
                            .firstIndex(where: { $0.id == rule.id }) else { return }
                        settings.rules.rules[index].isEnabled = value
                    }
                }))
            .labelsHidden()

            CommittingTextField(
                placeholder: "What should be done",
                value: rule.text,
                axis: .vertical
            ) { edited in
                model.update { settings in
                    guard let index = settings.rules.rules
                        .firstIndex(where: { $0.id == rule.id }) else { return }
                    settings.rules.rules[index].text = edited
                }
            }
            .textFieldStyle(.plain)

            Button(role: .destructive) {
                model.update { settings in
                    settings.rules.rules.removeAll { $0.id == rule.id }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: -

private struct ShortcutsTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorder(
                            combination: model.settings.combination(for: action)
                        ) { chosen in
                            model.update { settings in
                                settings.bindings.removeAll { $0.action == action }
                                if let chosen {
                                    settings.bindings.append(
                                        HotkeyBinding(action: action, combination: chosen))
                                }
                            }
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Click a shortcut, then press the keys you want. "
                         + "A spare mouse button works too — the middle one, or "
                         + "any button past it.")
                    Text("Esc keeps what was there, Delete clears it. The left and "
                         + "right mouse buttons are not offered: bound to one of "
                         + "those, you could not click anything again.")
                    Text("Ctrl+Space will not work either. macOS gives it to the "
                         + "input source switcher, so a shortcut registered there "
                         + "never arrives.")
                }
                .font(.caption)
            }

            let problems = model.settings.bindings.problems()
            if !problems.isEmpty {
                Section("Problems") {
                    ForEach(problems.indices, id: \.self) { index in
                        Label(problems[index].message,
                              systemImage: "exclamationmark.triangle")
                    }
                }
            }

            if !model.refusedShortcuts.isEmpty {
                Section("Already taken") {
                    ForEach(model.refusedShortcuts, id: \.action) { binding in
                        Text("""
                        \(binding.combination.displayName) belongs to something \
                        else, so \(binding.action.label.lowercased()) has no key.
                        """)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: -

private struct AgentTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Text("""
                Dictation puts text where you were typing. The agent is the other \
                thing you might want to do with your voice: ask a question and \
                read the answer.
                """)
                Text("""
                Press the agent key, say what you want, press it again. What you \
                said becomes the question — it is not cleaned up first and it is \
                not pasted anywhere. The reply opens in the Agent window, and the \
                next question continues the same conversation until you clear it.
                """)
                .foregroundStyle(.secondary)
            } header: {
                Text("What this is")
            }

            Section("Turn it on") {
                Toggle("Let me ask the agent by voice", isOn: enabledBinding)
                if let key = model.settings.combination(for: .agent) {
                    LabeledContent("The key", value: key.displayName)
                }
                LabeledContent("The claude command") {
                    if model.agentAvailable {
                        Label("Found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ModelPicker(title: "Answer with", selection: model.settings.agentModel) {
                    chosen in model.update { $0.agentModel = chosen }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("""
                This one answers your questions. It has nothing to do with \
                transcription — the speech recognition is Apple's and runs on this \
                Mac — and nothing to do with cleaning up dictation, which has its \
                own model on the Cleanup tab.
                """)
                .font(.caption)
            }

            Section {
                Button("Put every setting back to its default", role: .destructive) {
                    model.resetSettings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.settings.agentEnabled },
                set: { value in model.update { $0.agentEnabled = value } })
    }
}

// MARK: -

extension HotkeyAction {
    var label: String {
        switch self {
        case .toggle: "Start and stop"
        case .cancel: "Throw it away"
        case .agent: "Ask the agent"
        }
    }
}

extension PermissionKind {
    var settingsLabel: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech recognition"
        case .keyboardControl: "Pressing keys (for pasting)"
        }
    }
}

extension BindingProblem {
    var message: String {
        switch self {
        case .duplicate(let combination, let actions):
            "\(combination.displayName) is set for \(actions.map(\.label).joined(separator: " and "))."
        case .noModifiers(let action, let combination):
            "\(action.label) is set to \(combination.displayName), which would swallow that key everywhere."
        case .reservedBySystem(let action, let combination, let owner):
            """
            \(combination.displayName) will not reach Diktaf: macOS uses it for \
            \(owner). \(action.label) needs another combination.
            """
        }
    }
}

extension Locale {
    var localizedString: String? {
        Locale.current.localizedString(forIdentifier: identifier)
    }
}
