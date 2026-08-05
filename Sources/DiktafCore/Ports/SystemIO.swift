import Foundation

/// The system clipboard.
public protocol Clipboard: Sendable {
    func text() -> String?
    func setText(_ text: String)
}

/// Putting text into whatever window the user was typing in.
///
/// Two ways, because neither is always right. Pasting is instant and keeps
/// formatting out of it, but it needs the clipboard, which is not always the
/// user's to overwrite. Typing leaves the clipboard alone and works where
/// pasting is refused, but it is slow and some applications mangle it.
public protocol KeyboardSender: Sendable {
    /// Presses the platform's paste combination.
    func paste() throws

    /// Types the text out, character by character.
    func type(_ text: String) throws
}

/// Keeping the keyboard where the user left it.
///
/// Showing any window at all — even one that cannot be activated, belonging to
/// an application that stays in the background — can leave the window that had
/// the keyboard no longer holding it. Not the focus: the application in front
/// does not change and nothing moves on screen, but typed characters stop
/// arriving where they were going. So the target is noted before the indicator
/// appears and handed back before anything is typed.
public protocol FocusGuard: Sendable {
    /// Notes where the keyboard is now.
    func remember()

    /// Gives it back, if it moved. Doing this when nothing moved is harmless
    /// and is the normal case.
    func restore()
}
