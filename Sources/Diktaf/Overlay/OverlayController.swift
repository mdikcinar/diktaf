import AppKit
import DiktafCore
import Observation
import SwiftUI

/// The indicator that appears while Diktaf is listening.
///
/// An AppKit panel rather than a SwiftUI window, and every one of these settings
/// is load-bearing:
///
///   * `.nonactivatingPanel` and `becomesKeyOnlyIfNeeded` so that showing it does
///     not bring Diktaf to the front;
///   * `hidesOnDeactivate = false` because a utility panel is otherwise hidden
///     whenever its own application is not the active one, which is every moment
///     this exists for;
///   * `.canJoinAllSpaces` and `.fullScreenAuxiliary` so it follows the user
///     between desktops and appears beside a full-screen window rather than
///     replacing it;
///   * `ignoresMouseEvents` because it is something to look at, not to click.
///
/// None of it prevents the one thing that cannot be prevented: showing any window
/// at all can take the key window away from whatever the user was typing in.
/// That is what `FocusGuard` is for.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var watcher: Task<Void, Never>?

    /// Starts mirroring the model's state.
    func follow(_ model: AppModel) {
        watcher?.cancel()
        watcher = Task { @MainActor in
            // Observation rather than a stream: this is the interface layer, and
            // redrawing on change is exactly what it is for.
            while !Task.isCancelled {
                let shouldShow = model.settings.showOverlay && model.state.isBusy
                if shouldShow {
                    show(model)
                } else {
                    hide()
                }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = model.state
                        _ = model.settings.showOverlay
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func show(_ model: AppModel) {
        let panel = panel ?? makePanel(for: model)
        self.panel = panel
        position(panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the second
        // would hand this panel the keyboard, which is the one thing an indicator
        // must never take.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(for model: AppModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: RecordingIndicator(model: model))
        return panel
    }

    /// Bottom centre of the screen with the pointer on it, which is where the
    /// user is looking and out of the way of what they are typing.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 96
        ))
    }
}
