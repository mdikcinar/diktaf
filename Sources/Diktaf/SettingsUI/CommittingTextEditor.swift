import SwiftUI

/// `CommittingTextField` for text that runs to paragraphs.
///
/// The same arrangement — the editor owns its text while it is being edited and
/// the settings are told once — but Return is a new line here rather than a
/// commit, so only clicking away commits. Closing the window counts as clicking
/// away, or an edit made just before it would be lost.
struct CommittingTextEditor: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(value: String, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.onCommit = onCommit
        self._text = State(initialValue: value)
    }

    var body: some View {
        TextEditor(text: $text)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused, text != value { onCommit(text) }
            }
            .onDisappear {
                if text != value { onCommit(text) }
            }
            .onChange(of: value) { _, latest in
                if !isFocused, latest != text { text = latest }
            }
    }
}
