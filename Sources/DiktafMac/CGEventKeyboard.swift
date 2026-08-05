import CoreGraphics
import DiktafCore
import Foundation

/// Pressing keys on the user's behalf.
///
/// Through Quartz rather than by asking `osascript` to do it, for one reason
/// that matters: the permission belongs to whoever posts the event. `osascript`
/// is a program of Apple's that Diktaf happens to run, and macOS judges the
/// event by the application responsible for it — which is not the one the user
/// allowed in the settings.
///
/// And the thing to know before debugging this for an afternoon: **macOS reports
/// success either way**. Post a key event without having been granted
/// Accessibility and every call returns cleanly, nothing is logged, and the key
/// reaches nobody. There is no error to catch, which is why the caller asks
/// `PermissionAuthority` first rather than finding out afterwards.
public struct CGEventKeyboard: KeyboardSender {
    /// The combination that means paste on this platform.
    private let pasteCombination: KeyCombination

    public init(pasteCombination: KeyCombination = KeyCombination(key: "v", modifiers: [.command])) {
        self.pasteCombination = pasteCombination
    }

    public func paste() throws {
        guard let key = KeyCodes.virtualKey(for: pasteCombination.key) else {
            throw KeyboardFailure.unknownKey(pasteCombination.key)
        }
        try press(key: key, flags: KeyCodes.eventFlags(pasteCombination.modifiers))
    }

    /// Types the text out as characters rather than as key presses.
    ///
    /// `keyboardSetUnicodeString` rather than a character-to-key-code table: the
    /// table would be wrong on every layout but the one it was written for, and
    /// a dictation in Turkish typed on a Turkish keyboard would come out as
    /// something else entirely.
    public func type(_ text: String) throws {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        // In chunks, because a single event carries a bounded string and a
        // dictation is routinely longer than one.
        for chunk in text.chunked(into: 20) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw KeyboardFailure.couldNotCreateEvent }

            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Posted where the hardware would have, so every application sees it the
    /// way it sees a real key.
    private func press(key: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw KeyboardFailure.couldNotCreateEvent }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

public enum KeyboardFailure: Error, Sendable, Equatable {
    case unknownKey(String)
    case couldNotCreateEvent
}

extension String {
    fileprivate func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}
