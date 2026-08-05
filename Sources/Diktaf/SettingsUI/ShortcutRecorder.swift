import AppKit
import DiktafCore
import DiktafMac
import SwiftUI

/// One field per shortcut: click it, press the combination, done.
///
/// Recording rather than typing, because typing a shortcut means knowing what
/// Diktaf calls the key — and being asked to spell "Ctrl+Alt+Space" is a worse
/// experience than pressing it. It reads modifiers from the event, so any
/// combination the keyboard can produce can be bound, and it accepts a spare
/// mouse button as well.
///
/// A **local** `NSEvent` monitor does the recording, which is the reason this
/// needs no permission: the settings window is the active window while the user
/// is arming and pressing, so the events come to Diktaf anyway.
struct ShortcutRecorder: View {
    let combination: KeyCombination?
    let onChange: (KeyCombination?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(label)
                .font(.body.monospaced())
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(minWidth: 170, alignment: .center)
                .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .help(isRecording
              ? "Press a combination, or Esc to keep the current one"
              : "Click, then press the combination you want")
        .overlay(alignment: .trailing) {
            if combination != nil, !isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove this shortcut")
                .offset(x: 20)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press a key…" }
        return combination?.displayName ?? "None"
    }

    // MARK: - Recording

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .otherMouseDown]
        ) { event in
            // Every event is swallowed while armed. Letting one through would
            // type into whatever is behind, and the user is pressing keys they
            // do not mean as text.
            switch event.type {
            case .keyDown:
                handle(keyDown: event)
            case .otherMouseDown:
                commit(KeyCombination.mouseButton(
                    event.buttonNumber, modifiers: event.modifierFlags.asCombinationModifiers))
            default:
                break
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(keyDown event: NSEvent) {
        let modifiers = event.modifierFlags.asCombinationModifiers

        // Escape alone leaves things as they were, and Delete alone clears —
        // neither is bindable, which is the price of both being the obvious way
        // out of a field that is swallowing every key.
        if modifiers.isEmpty {
            switch Int(event.keyCode) {
            case 53:
                stopRecording()
                return
            case 51, 117:
                commit(nil)
                return
            default:
                break
            }
        }

        guard let name = ShortcutRecorder.keyName(for: event) else {
            NSSound.beep()
            return
        }
        commit(KeyCombination(key: name, modifiers: modifiers))
    }

    private func commit(_ combination: KeyCombination?) {
        stopRecording()
        onChange(combination)
    }

    /// The portable name for the key that was pressed.
    ///
    /// From the key code rather than from the typed characters, because the
    /// characters depend on the layout and on which modifiers were held: pressing
    /// Alt+D on a Turkish keyboard does not produce "d", and a shortcut that only
    /// works on one layout is worse than no shortcut.
    private static func keyName(for event: NSEvent) -> String? {
        KeyCodes.portableName(forVirtualKey: event.keyCode)
    }
}
