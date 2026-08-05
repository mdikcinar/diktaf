import Carbon.HIToolbox
import DiktafCore
import Foundation

/// Keys that reach Diktaf while another application has the keyboard.
///
/// `RegisterEventHotKey` rather than an `NSEvent` global monitor or an event tap,
/// because it is the only one of the three that works for an accessory
/// application without Accessibility permission. A dictation key that stops
/// working until the user visits System Settings is a dictation key that does not
/// work.
public final class CarbonHotkeyMonitor: HotkeyMonitor {
    public init() {}

    @discardableResult
    public func rebind(
        _ bindings: [HotkeyBinding],
        onTrigger: @escaping @Sendable (HotkeyAction) -> Void
    ) -> [HotkeyBinding] {
        HotkeyRegistry.shared.rebind(bindings, onTrigger: onTrigger)
    }

    public func unbindAll() {
        HotkeyRegistry.shared.unbindAll()
    }
}

/// The registered keys, and the one Carbon handler they all arrive through.
///
/// A singleton because Carbon's is: `InstallEventHandler` is process-wide, its
/// callback is a C function pointer with no captured context, and the only way
/// back to Swift state is a table this side of it.
private final class HotkeyRegistry: @unchecked Sendable {
    static let shared = HotkeyRegistry()

    /// Guards everything below. Carbon calls the handler on the main thread and
    /// the settings window rebinds from wherever it happens to be, so the two do
    /// meet.
    private let lock = NSLock()
    private var registered: [UInt32: (action: HotkeyAction, reference: EventHotKeyRef)] = [:]
    private var handler: EventHandlerRef?
    private var trigger: (@Sendable (HotkeyAction) -> Void)?
    private var nextID: UInt32 = 1

    /// Diktaf's own four-character signature, which is how Carbon tells one
    /// application's hotkeys from another's.
    private static let signature = OSType(0x44_4B_54_46)     // 'DKTF'

    func rebind(
        _ bindings: [HotkeyBinding],
        onTrigger: @escaping @Sendable (HotkeyAction) -> Void
    ) -> [HotkeyBinding] {
        lock.lock()
        defer { lock.unlock() }

        releaseAllLocked()
        trigger = onTrigger
        installHandlerLocked()

        var refused: [HotkeyBinding] = []
        for binding in bindings {
            guard let key = KeyCodes.virtualKey(for: binding.combination.key) else {
                refused.append(binding)
                continue
            }

            let id = nextID
            nextID += 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(key),
                KeyCodes.carbonModifiers(binding.combination.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &reference
            )

            // Anything non-zero here is almost always another application
            // holding the combination already. Reported rather than thrown: the
            // rest of the keys are still worth registering, and the settings
            // window can say which one to change.
            if status == noErr, let reference {
                registered[id] = (binding.action, reference)
            } else {
                refused.append(binding)
            }
        }
        return refused
    }

    func unbindAll() {
        lock.lock()
        defer { lock.unlock() }
        releaseAllLocked()
        trigger = nil
    }

    private func releaseAllLocked() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.reference) }
        registered.removeAll()
    }

    private func installHandlerLocked() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in HotkeyRegistry.shared.handle(event) },
            1,
            &type,
            nil,
            &handler
        )
    }

    /// Called by Carbon. Reads which key fired and hands it on.
    fileprivate func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard status == noErr, id.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }

        lock.lock()
        let action = registered[id.id]?.action
        let trigger = self.trigger
        lock.unlock()

        // Outside the lock: the handler runs the dictation, and holding a lock
        // across that would mean a rebind could not happen while one was in
        // flight.
        guard let action, let trigger else { return OSStatus(eventNotHandledErr) }
        trigger(action)
        return noErr
    }
}
