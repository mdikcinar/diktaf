import AppKit
import DiktafCore

/// Keeping the keyboard where the user left it.
///
/// Showing any window at all can leave the window that had the keyboard no
/// longer holding it. Not the focus — the application in front does not change
/// and nothing moves on screen — but the key window, which is where a typed
/// character actually arrives. There is no flag that prevents it: not a panel
/// that cannot become key, not an accessory application, not a window shown
/// without activating.
///
/// So the application that had the keyboard is noted before the indicator
/// appears and activated again just before anything is typed. It is already the
/// frontmost one, so this puts back only what macOS quietly took and undoes
/// nothing the user did.
public final class AppKitFocusGuard: FocusGuard {
    /// Which application had it. Held weakly on purpose: an application that has
    /// quit in the meantime is not one to activate, and keeping it alive here
    /// would be worse than losing the paste.
    private let remembered = Remembered()

    public init() {}

    public func remember() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Diktaf itself is never the answer. If it is already frontmost — the
        // user clicked the menu bar icon rather than pressing the key — there is
        // no other window to hand the keyboard back to.
        if frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            remembered.application = nil
        } else {
            remembered.application = frontmost
        }
    }

    public func restore() {
        guard let application = remembered.application, !application.isTerminated else { return }
        guard application.processIdentifier
                != NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return                     // never left; nothing to put back
        }
        application.activate(options: [])
    }

    /// A box, because `FocusGuard` is synchronous and Sendable while
    /// `NSRunningApplication` is neither.
    private final class Remembered: @unchecked Sendable {
        private let lock = NSLock()
        private weak var stored: NSRunningApplication?

        var application: NSRunningApplication? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
