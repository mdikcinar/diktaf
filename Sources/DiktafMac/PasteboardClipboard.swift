import AppKit
import DiktafCore

/// The system clipboard, as NSPasteboard.
public struct PasteboardClipboard: Clipboard {
    public init() {}

    public func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Cleared before it is written, which is not optional: a pasteboard still
    /// holding an older representation of the same type — RTF from one
    /// application, a file URL from another — can have that one pasted instead
    /// of the plain text just put there.
    public func setText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
