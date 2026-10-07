import DiktafCore
import SwiftUI

struct SettingsWindow: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Genel", systemImage: "gearshape") {
                GeneralTab(model: model)
            }
            Tab("Temizleme", systemImage: "wand.and.sparkles") {
                CleanupTab(model: model)
            }
            Tab("Kısayollar", systemImage: "keyboard") {
                ShortcutsTab(model: model)
            }
            Tab("Agent", systemImage: "bubble.left.and.text.bubble.right") {
                AgentTab(model: model)
            }
        }
        .task { await model.refreshPermissions() }
        .task { await model.refreshLocales() }
        .task { model.refreshWhisperState() }
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
            Section {
                Picker("Ses tanıyıcı", selection: engineBinding) {
                    Text("macOS tanıyıcısı").tag(TranscriptionEngine.system)
                    Text("Whisper, bu Mac'te").tag(TranscriptionEngine.whisper)
                }

                if model.settings.engine == .whisper {
                    Picker("Model", selection: whisperModelBinding) {
                        ForEach(model.whisperChoices) { choice in
                            Text(choice.megabytes > 0
                                 ? "\(choice.label) — \(choice.megabytes) MB"
                                 : choice.label)
                                .tag(String?.some(choice.variant))
                        }
                    }
                    WhisperStateRow(model: model)
                }
            } header: {
                Text("Tanıyıcı")
            } footer: {
                Text(engineExplanation)
                    .font(.caption)
            }

            Section {
                Picker("Dikte dili", selection: languageBinding) {
                    Text("Sistemle aynı — \(model.chosenLocale.readableName)")
                        .tag(String?.none)
                    Divider()
                    ForEach(model.languageChoices, id: \.identifier) { choice in
                        Text(choice.label).tag(String?.some(choice.identifier))
                    }
                }

                if model.settings.engine == .system {
                    LanguageStateRow(model: model)
                }
            } header: {
                Text("Dil")
            } footer: {
                Text(languageExplanation)
                    .font(.caption)
            }

            Section("Metin nereye gider") {
                Picker("Metni", selection: deliveryBinding) {
                    Text("Yapıştır").tag(DeliveryMode.paste)
                    Text("Tuşlarla yaz").tag(DeliveryMode.type)
                    Text("Panoda bırak").tag(DeliveryMode.clipboardOnly)
                }
                Text(deliveryExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sessizlikte kendiliğinden bitir", isOn: silenceStopBinding)
                if model.settings.silenceStopEnabled {
                    LabeledContent("Ne kadar sessizlik") {
                        Stepper(
                            AppModel.seconds(model.silenceStopDelay),
                            value: silenceSecondsBinding, in: 1...15, step: 0.5)
                    }
                }
            } header: {
                Text("Kaydı bitirme")
            } footer: {
                Text(model.settings.silenceStopEnabled
                     ? "Konuşmaya başladıktan sonra bu kadar sessizlik olunca dikte biter, "
                       + "tuşa yeniden basmışsınız gibi. Konuşmadan önceki sessizlik sayılmaz. "
                       + "Göstergede geri sayım görünür; konuşmaya devam ederseniz sıfırlanır."
                     : "Dikte yalnızca kısayolla ya da göstergedeki Bitir düğmesiyle biter.")
                    .font(.caption)
            }

            Section("Gösterge") {
                Toggle("Kayıt sırasında göster", isOn: overlayBinding)
            }

            Section("İzinler") {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    LabeledContent(kind.settingsLabel) {
                        PermissionRow(model: model, kind: kind)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// What the choice actually costs, in the terms somebody is choosing on.
    ///
    /// Both sentences are about trade-offs rather than quality, because neither
    /// engine wins outright: one is free and instant and mishears technical words,
    /// the other hears them and costs a download and a couple of seconds.
    private var engineExplanation: String {
        switch model.settings.engine {
        case .system:
            """
            macOS'un yerleşik tanıyıcısı; sistemin kendi diktesi de bunu kullanır. \
            İndirme gerekmez, hemen başlar, kelimeler siz konuşurken belirir. \
            Ama beklemediği adları yanlış duyar: "Firebase CLI" gibi bir terimi \
            başka bir şeye çevirir.
            """
        case .whisper:
            """
            Whisper, Core ML ile bu Mac'te çalışır; hiçbir şey dışarı çıkmaz. \
            Yazılım terimlerini desteklediği her dilde tanır — seçilmesinin nedeni \
            bu. Bedeli: bir kerelik indirme, yeniden başlatmadan sonra birkaç \
            saniyelik yükleme ve göstergede kelime kelime değil kaba bir önizleme. \
            Asıl metin, konuşmanız bitince tek geçişte çıkarılır.
            """
        }
    }

    private var languageExplanation: String {
        switch model.settings.engine {
        case .system:
            """
            macOS tanıyıcısının her dil için ayrı bir modeli var \
            (\(model.supportedLocales.count) dil) ve diskte yalnızca \
            kullandıklarınızı tutar. ✓ işareti modelin zaten yüklü olduğunu gösterir.
            """
        case .whisper:
            """
            Tek bir Whisper modeli bildiği her dili kapsar; bu dil için ayrıca \
            indirilecek bir şey yok. Yine de dili seçmek işe yarar: kendi haline \
            bırakılan Whisper dili ilk birkaç saniyeden tahmin eder ve İngilizce \
            bir ürün adıyla başlayan cümlede tam da bunu yanlış yapar.
            """
        }
    }

    private var deliveryExplanation: String {
        switch model.settings.delivery {
        case .paste:
            "Hızlı ve neredeyse her zaman istediğiniz bu. Panoyu kullanır."
        case .type:
            "Daha yavaş, ama panoya dokunmaz ve yapıştırmaya izin vermeyen yerlerde de çalışır."
        case .clipboardOnly:
            "Sizin yerinize hiçbir tuşa basılmaz, bu yüzden erişilebilirlik izni gerekmez."
        }
    }

    private var languageBinding: Binding<String?> {
        Binding(get: { model.settings.language },
                set: { value in model.update { $0.language = value } })
    }

    private var engineBinding: Binding<TranscriptionEngine> {
        Binding(get: { model.settings.engine },
                set: { value in model.update { $0.engine = value } })
    }

    private var whisperModelBinding: Binding<String?> {
        Binding(get: { model.chosenWhisperModel.variant },
                set: { value in model.update { $0.whisperModel = value } })
    }

    private var deliveryBinding: Binding<DeliveryMode> {
        Binding(get: { model.settings.delivery },
                set: { value in model.update { $0.delivery = value } })
    }

    private var overlayBinding: Binding<Bool> {
        Binding(get: { model.settings.showOverlay },
                set: { value in model.update { $0.showOverlay = value } })
    }

    private var silenceStopBinding: Binding<Bool> {
        Binding(get: { model.settings.silenceStopEnabled },
                set: { value in model.update { $0.silenceStopEnabled = value } })
    }

    private var silenceSecondsBinding: Binding<Double> {
        Binding(get: { model.silenceStopDelay },
                set: { value in model.update { $0.silenceStopSeconds = value } })
    }
}

/// Whether the chosen language can be dictated in, and what to do if not.
///
/// Stated rather than left to fail at the first dictation: a model takes minutes
/// to fetch, and a dictation quietly waiting for one is indistinguishable from a
/// dictation that is broken.
private struct LanguageStateRow: View {
    let model: AppModel

    var body: some View {
        switch model.languageState {
        case .installed:
            LabeledContent("Konuşma modeli") {
                Label("Hazır", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .notInstalled:
            LabeledContent("Konuşma modeli") {
                if let installing = model.modelInstallation {
                    ProgressView(installing.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                } else {
                    Button("İndir") {
                        Task { await model.installModel(for: model.chosenLocale) }
                    }
                }
            }
        case .downloading:
            LabeledContent("Konuşma modeli") {
                Label("Arka planda indiriliyor", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        case .unsupported:
            LabeledContent("Konuşma modeli") {
                Label("Bu dil için yok", systemImage: "xmark.circle")
                    .foregroundStyle(.orange)
            }
        case nil:
            LabeledContent("Konuşma modeli") { ProgressView().controlSize(.small) }
        }
    }
}

/// Whether the chosen Whisper model is here, and the button that fetches it.
///
/// The counterpart of `LanguageStateRow`, and the same reasoning: a model takes
/// minutes to fetch, so the asking happens here rather than at the first
/// dictation, where a wait is indistinguishable from a hang.
///
/// The one thing this says that the other does not is what the model is *for*,
/// under the download button. Six hundred megabytes is a decision, and somebody
/// making it is entitled to know what they get.
private struct WhisperStateRow: View {
    let model: AppModel

    var body: some View {
        LabeledContent("Model dosyaları") {
            switch (model.whisperInstallation, model.whisperState) {
            case (.downloading(let progress), _):
                ProgressView(progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            case (.preparing, _):
                // No bar, because there is no percentage to put in one: Core ML is
                // compiling the network for this chip and does not say how far
                // along it is. A bar stuck at 100% reads as a hang.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Bu Mac için hazırlanıyor").foregroundStyle(.secondary)
                }
            case (nil, .installed):
                HStack(spacing: 12) {
                    Label("Hazır", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Kaldır") { model.removeWhisperModel() }
                        .controlSize(.small)
                }
            case (nil, .notInstalled):
                Button("İndir (\(model.chosenWhisperModel.megabytes) MB)") {
                    Task { await model.installWhisperModel() }
                }
            case (nil, nil):
                ProgressView().controlSize(.small)
            }
        }

        Text(model.chosenWhisperModel.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct PermissionRow: View {
    let model: AppModel
    let kind: PermissionKind

    var body: some View {
        switch model.permissions[kind] ?? .undetermined {
        case .granted:
            Label("İzin verildi", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .undetermined:
            Button("İzin iste") { Task { await model.request(kind) } }
        case .denied:
            // Asking again achieves nothing once the answer was no; the pane is
            // the only route left.
            Button("Sistem Ayarları'nı aç") { model.openSettings(for: kind) }
        }
    }
}

// MARK: -

private struct CleanupTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Dikte ettiğimi temizle", isOn: enabledBinding)
                Text("""
                Duyulan metin, aşağıdaki kurallar uygulansın diye temizleme \
                motoruna gider; yapıştırılan onun sonucudur. Konuşmayı metne \
                çeviren o değil, ses tanıyıcıdır. Kapalıyken ham metin olduğu \
                gibi yapıştırılır; temizleme başarısız olur ya da çok uzun \
                sürerse de öyle.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Temizleme motoru", selection: engineBinding) {
                    Text("Ollama, bu Mac'te").tag(CleanupEngine.ollama)
                    Text("Claude").tag(CleanupEngine.claude)
                }

                switch model.settings.cleanupEngine {
                case .ollama:
                    Picker("Model", selection: ollamaModelBinding) {
                        ForEach(model.ollamaChoices, id: \.self) { choice in
                            Text(isPulled(choice) ? choice : "\(choice) — indirilmemiş")
                                .tag(choice)
                        }
                    }
                    OllamaStateRow(model: model)
                case .claude:
                    ModelPicker(title: "Model", selection: model.settings.cleanupModel) {
                        chosen in model.update { $0.cleanupModel = chosen }
                    }
                }

                LabeledContent("Zaman aşımı") {
                    Stepper(
                        "\(model.settings.refinerTimeoutSeconds) sn",
                        value: timeoutBinding, in: 3...120, step: 1)
                }
            } header: {
                Text("Motor")
            } footer: {
                Text(engineExplanation)
                    .font(.caption)
            }

            Section("Kurallar") {
                ForEach(model.settings.rules.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
                Button("Kural ekle", systemImage: "plus") {
                    model.update { $0.rules.rules.append(CleanupRule(text: "")) }
                }
            }

            Section("Ek talimat") {
                CommittingTextField(
                    placeholder: "Yukarıdaki kuralların kapsamadığı her şey",
                    value: model.settings.rules.extraInstruction ?? "",
                    axis: .vertical
                ) { edited in
                    let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.update { $0.rules.extraInstruction = trimmed.isEmpty ? nil : trimmed }
                }
                .lineLimit(3...)
                Text("Serbest metin. Sürekli yanlış duyduğu bir ad, bir yazım üslubu, kaçınılacak bir kelime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Önerilen kuralları geri yükle") {
                    model.update { $0.rules = .recommended }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshOllama() }
    }

    /// The trade-off between the two engines, as `GeneralTab` states it for the
    /// recognisers: speed and setup against how well each one removes Turkish
    /// fillers and repetitions.
    private var engineExplanation: String {
        switch model.settings.cleanupEngine {
        case .ollama:
            """
            Ollama bu Mac'te çalışır ve hızlıdır: model belleğe yüklendikten \
            sonra bir dikte yaklaşık 1 saniyede temizlenir, Claude'da bu 7–15 \
            saniye sürer. Model, dikte başlarken belleğe alınır ve ~8 GB bellek \
            kullanır. Ollama'ya ulaşılamazsa temizlemeyi kendiliğinden Claude \
            yapar. Önerilen gemma4:12b Türkçede Claude'a yakın sonuç verir; \
            "salı… yok, çarşamba" gibi kendini düzeltmeleri bazen iki haliyle \
            bırakır.
            """
        case .claude:
            """
            Claude, bu Mac'te oturum açılmış claude komutuyla çalışır. Her temizleme \
            birkaç saniye sürer, ama Türkçede dolgu kelimelerini ve tekrarları \
            Ollama'daki önerilen modelden daha iyi ayıklar. Her diktede çalıştığı \
            için hızlı model yeterli: en küçüğü en büyüğünden bir iki saniye \
            hızlıdır ve bu işi gayet iyi yapar.
            """
        }
    }

    /// Only said of a model while Ollama is answering: with the server down the
    /// list is empty, and every name would look missing.
    private func isPulled(_ name: String) -> Bool {
        model.ollamaRunning != true || model.ollamaModels.contains(name)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.settings.cleanupEnabled },
                set: { value in model.update { $0.cleanupEnabled = value } })
    }

    private var engineBinding: Binding<CleanupEngine> {
        Binding(get: { model.settings.cleanupEngine },
                set: { value in model.update { $0.cleanupEngine = value } })
    }

    private var ollamaModelBinding: Binding<String> {
        Binding(get: { model.chosenOllamaModel },
                set: { value in model.update { $0.ollamaModel = value } })
    }

    private var timeoutBinding: Binding<Int> {
        Binding(get: { model.settings.refinerTimeoutSeconds },
                set: { value in model.update { $0.refinerTimeoutSeconds = value } })
    }
}

/// Whether Ollama can clean up with the chosen model, and what to do if not.
///
/// The counterpart of `WhisperStateRow`, minus the download button: Ollama
/// fetches its own models, so the most this can offer is the command to run.
private struct OllamaStateRow: View {
    let model: AppModel

    var body: some View {
        LabeledContent("Durum") {
            HStack(spacing: 12) {
                switch model.ollamaRunning {
                case nil:
                    ProgressView().controlSize(.small)
                case false?:
                    Label("Ollama çalışmıyor", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                case true? where !model.ollamaHasChosenModel:
                    Text(verbatim: pullCommand)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button("Kopyala", systemImage: "doc.on.doc") {
                        PasteboardWriter.write(pullCommand)
                    }
                    .controlSize(.small)
                case true?:
                    Label("Hazır", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Yenile") { Task { await model.refreshOllama() } }
                    .controlSize(.small)
            }
        }

        if model.ollamaRunning == false {
            Text("`ollama serve` ile başlatın; o sırada temizlemeyi Claude yapar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.ollamaRunning == true, !model.ollamaHasChosenModel {
            Text("Model indirilmemiş; bu komutu terminalde çalıştırın. O sırada temizlemeyi Claude yapar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pullCommand: String {
        "ollama pull \(model.chosenOllamaModel)"
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
                placeholder: "Ne yapılsın",
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
                        } onRecordingChange: { isRecording in
                            isRecording
                                ? model.beginRecordingShortcut()
                                : model.endRecordingShortcut()
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bir kısayola tıklayın, sonra istediğiniz tuşlara basın. "
                         + "Boştaki bir fare düğmesi de olur: orta düğme ya da "
                         + "ondan sonrakiler.")
                    Text("Esc eskisini korur, Delete siler. Sol ve sağ fare "
                         + "düğmeleri sunulmaz: onlardan birine atanırsa hiçbir "
                         + "şeye tıklayamazsınız.")
                    Text("Ctrl+Space de çalışmaz: macOS onu giriş kaynağını "
                         + "değiştirmeye ayırır, oraya atanan kısayol hiç ulaşmaz.")
                }
                .font(.caption)
            }

            let problems = model.settings.bindings.problems()
            if !problems.isEmpty {
                Section("Sorunlar") {
                    ForEach(problems.indices, id: \.self) { index in
                        Label(problems[index].message,
                              systemImage: "exclamationmark.triangle")
                    }
                }
            }

            if !model.refusedShortcuts.isEmpty {
                Section("Zaten kullanımda") {
                    ForEach(model.refusedShortcuts, id: \.action) { binding in
                        Text("""
                        \(binding.combination.displayName) başka bir şey tarafından \
                        kullanılıyor; “\(binding.action.label)” için tuş atanamadı.
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
                Dikte, metni yazdığınız yere koyar. Agent ise sesinizle \
                yapabileceğiniz öbür şey: bir soru sorun, yanıtı okuyun.
                """)
                Text("""
                Agent tuşuna basın, ne istediğinizi söyleyin, yeniden basın. \
                Söyledikleriniz soru olur: önce temizlenmez, hiçbir yere \
                yapıştırılmaz. Yanıt Agent penceresinde açılır; siz yeni bir \
                konuşma başlatana kadar sonraki soru aynı konuşmayı sürdürür.
                """)
                .foregroundStyle(.secondary)
            } header: {
                Text("Bu nedir")
            }

            Section("Etkinleştir") {
                Toggle("Agent'a sesle sorabileyim", isOn: enabledBinding)
                if let key = model.settings.combination(for: .agent) {
                    LabeledContent("Tuş", value: key.displayName)
                }
                LabeledContent("claude komutu") {
                    if model.agentAvailable {
                        Label("Bulundu", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Kurulu değil", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ModelPicker(title: "Yanıtlayan", selection: model.settings.agentModel) {
                    chosen in model.update { $0.agentModel = chosen }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("""
                Bu model sorularınızı yanıtlar. Konuşmayı metne çevirmekle ilgisi \
                yoktur — o, Genel sekmesindeki ses tanıyıcının işidir — dikteyi \
                temizlemekle de: onun kendi ayarları Temizleme sekmesinde.
                """)
                .font(.caption)
            }

            Section {
                Button("Tüm ayarları varsayılana döndür", role: .destructive) {
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
        case .toggle: "Dikteye başla / bitir"
        case .cancel: "Kaydı at"
        case .agent: "Agent'a sor"
        }
    }
}

extension PermissionKind {
    var settingsLabel: String {
        switch self {
        case .microphone: "Mikrofon"
        case .speechRecognition: "Konuşma tanıma"
        case .keyboardControl: "Tuşlara basma (yapıştırmak için)"
        }
    }
}

extension BindingProblem {
    var message: String {
        switch self {
        case .duplicate(let combination, let actions):
            "\(combination.displayName) birden fazla işe atanmış: "
            + actions.map { "“\($0.label)”" }.joined(separator: " ve ") + "."
        case .noModifiers(let action, let combination):
            "“\(action.label)” için \(combination.displayName) seçilmiş; bu tuş başka hiçbir yerde çalışmaz."
        case .reservedBySystem(let action, let combination, let owner):
            """
            \(combination.displayName) Diktaf'a ulaşmaz: macOS onu kendisi \
            kullanıyor (\(owner)). “\(action.label)” için başka bir kombinasyon seçin.
            """
        }
    }
}

extension Locale {
    /// "Türkçe (Türkiye)" rather than "tr_TR", in the interface's language
    /// rather than the system's, so the list does not mix two languages.
    ///
    /// Falls back to the identifier rather than to nothing: an unfamiliar code in
    /// a menu is worse than an ugly one, but a blank row is worse than both.
    var readableName: String {
        Self.interface.localizedString(forIdentifier: identifier(.bcp47))
            ?? Self.interface.localizedString(forIdentifier: identifier)
            ?? identifier
    }

    private static let interface = Locale(identifier: "tr")
}
