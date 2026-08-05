import DiktafCore
import SwiftUI

/// Which model to ask, as a menu rather than a name to type.
///
/// A dropdown because the useful answers are a short list of aliases the command
/// already understands, and typing one means knowing how it is spelled. A value
/// that is not on the list — somebody put a full model name in the settings file
/// — is shown as an extra entry rather than silently replaced, because
/// overwriting a choice the user made by hand is worse than an unfamiliar item in
/// a menu.
struct ModelPicker: View {
    let title: String
    let selection: String?
    let onChange: (String?) -> Void

    /// The aliases `claude --model` takes, fastest first. Speed is the axis that
    /// matters here: cleanup happens on every dictation.
    private static let known = [
        (alias: "haiku", label: "Haiku — fastest, cheapest"),
        (alias: "sonnet", label: "Sonnet — balanced"),
        (alias: "opus", label: "Opus — most capable"),
        (alias: "fable", label: "Fable"),
    ]

    var body: some View {
        Picker(title, selection: binding) {
            Text("Whatever claude defaults to").tag(String?.none)
            ForEach(Self.known, id: \.alias) { model in
                Text(model.label).tag(String?.some(model.alias))
            }
            if let selection, !Self.known.contains(where: { $0.alias == selection }) {
                Divider()
                Text(selection).tag(String?.some(selection))
            }
        }
    }

    private var binding: Binding<String?> {
        Binding(get: { selection }, set: onChange)
    }
}
