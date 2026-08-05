import SwiftUI

/// A text field that does not fight the settings store.
///
/// Bound straight to the settings, a field writes on every keystroke — and since
/// storing a setting is asynchronous, the view is redrawn from the stored value
/// while the next character is still being typed. Letters go missing, the caret
/// jumps, and a field can look as though it refuses to be edited at all.
///
/// So the field owns its text while it is being edited, and the settings are told
/// once, when editing ends. That is also what a settings field on this platform
/// does: Return or clicking away commits.
struct CommittingTextField: View {
    let placeholder: String
    let value: String
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        value: String,
        axis: Axis = .horizontal,
        onCommit: @escaping (String) -> Void
    ) {
        self.placeholder = placeholder
        self.value = value
        self.axis = axis
        self.onCommit = onCommit
        self._text = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .focused($isFocused)
            .onSubmit { onCommit(text) }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit(text) }
            }
            // Changed from somewhere else — the rules put back to their defaults,
            // say. Taken only while the user is not in the middle of typing, so
            // this can never be what overwrites what they are writing.
            .onChange(of: value) { _, latest in
                if !isFocused, latest != text { text = latest }
            }
    }
}
