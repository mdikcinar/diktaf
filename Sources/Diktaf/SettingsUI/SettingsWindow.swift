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
                Cleanup runs through the claude command on this Mac. If it fails \
                or takes too long, the raw transcript is pasted instead.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                TextEditor(text: extraBinding)
                    .frame(minHeight: 60)
                    .font(.body)
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
        .disabled(!model.settings.cleanupEnabled && false)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.settings.cleanupEnabled },
                set: { value in model.update { $0.cleanupEnabled = value } })
    }

    private var extraBinding: Binding<String> {
        Binding(get: { model.settings.rules.extraInstruction ?? "" },
                set: { value in
                    model.update { $0.rules.extraInstruction = value.isEmpty ? nil : value }
                })
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

            TextField("What should be done", text: Binding(
                get: { rule.text },
                set: { value in
                    model.update { settings in
                        guard let index = settings.rules.rules
                            .firstIndex(where: { $0.id == rule.id }) else { return }
                        settings.rules.rules[index].text = value
                    }
                }), axis: .vertical)
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
                        ShortcutField(model: model, action: action)
                    }
                }
            } footer: {
                Text("""
                Ctrl+Space is not offered: macOS gives it to the input source \
                switcher, so a shortcut registered there never arrives.
                """)
                .font(.caption)
            }

            if !model.settings.bindings.problems().isEmpty {
                Section("Problems") {
                    ForEach(model.settings.bindings.problems().indices, id: \.self) { index in
                        Label(model.settings.bindings.problems()[index].message,
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

/// Typed rather than recorded by watching for a key press.
///
/// A recorder would have to take over the keyboard to catch the combination, and
/// the combinations worth binding are the ones another application would rather
/// have. Typing "Ctrl+Alt+Space" always works.
private struct ShortcutField: View {
    let model: AppModel
    let action: HotkeyAction

    @State private var text = ""
    @State private var isValid = true

    var body: some View {
        TextField("Ctrl+Alt+Space", text: $text)
            .frame(width: 180)
            .foregroundStyle(isValid ? Color.primary : Color.red)
            .onSubmit(commit)
            .onAppear {
                text = model.settings.combination(for: action)?.displayName ?? ""
            }
            .onChange(of: text) { _, new in
                isValid = new.isEmpty || KeyCombination(parsing: new) != nil
            }
    }

    private func commit() {
        guard let combination = KeyCombination(parsing: text) else {
            isValid = false
            return
        }
        isValid = true
        text = combination.displayName
        model.update { settings in
            settings.bindings.removeAll { $0.action == action }
            settings.bindings.append(HotkeyBinding(action: action, combination: combination))
        }
    }
}

// MARK: -

private struct AgentTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Let me ask the agent by voice", isOn: enabledBinding)
                LabeledContent("The claude command") {
                    if model.agentAvailable {
                        Label("Found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("""
                Diktaf uses the claude command you are already signed in to. \
                There is no API key to enter, and nothing is sent anywhere you \
                have not already agreed to.
                """)
                .font(.caption)
            }

            Section("Model") {
                TextField("haiku", text: modelBinding)
                Text("""
                An alias like haiku, sonnet or opus, or a full model name. Blank \
                uses whatever the command defaults to. Cleaning up one sentence \
                does not need the largest model, and the smaller ones are \
                seconds faster on every dictation.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var modelBinding: Binding<String> {
        Binding(get: { model.settings.agentModel ?? "" },
                set: { value in
                    model.update { $0.agentModel = value.isEmpty ? nil : value }
                })
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
        }
    }
}

extension Locale {
    var localizedString: String? {
        Locale.current.localizedString(forIdentifier: identifier)
    }
}
