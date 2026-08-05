import AppKit
import DiktafCore

/// Every shortcut Diktaf has, whether it is a key or a mouse button.
///
/// Two mechanisms behind one port, because no single API covers both:
///
///   * keys go to `RegisterEventHotKey`, which is the only way an accessory
///     application gets a key that another application is holding the keyboard
///     for — and it needs no permission;
///   * mouse buttons go to an `NSEvent` global monitor, because Carbon does not
///     register mouse buttons at all.
///
/// The split is invisible above this line. `HotkeyMonitor.rebind` still takes the
/// whole set and still reports what was refused.
public final class MacHotkeyMonitor: HotkeyMonitor {
    private let keys = CarbonHotkeyMonitor()
    private let mouse = MouseButtonMonitor()

    public init() {}

    @discardableResult
    public func rebind(
        _ bindings: [HotkeyBinding],
        onTrigger: @escaping @Sendable (HotkeyAction) -> Void
    ) -> [HotkeyBinding] {
        let mouseBindings = bindings.filter(\.combination.isMouseButton)
        let keyBindings = bindings.filter { !$0.combination.isMouseButton }

        return keys.rebind(keyBindings, onTrigger: onTrigger)
            + mouse.rebind(mouseBindings, onTrigger: onTrigger)
    }

    public func unbindAll() {
        keys.unbindAll()
        mouse.unbindAll()
    }
}

/// Mouse buttons, watched wherever they are pressed.
///
/// Two monitors rather than one, and both are needed: a global monitor sees
/// events destined for other applications but never Diktaf's own, and a local
/// monitor sees only Diktaf's. Without the local one the shortcut would stop
/// working the moment the settings window was in front.
///
/// Unlike a global monitor for *keys*, this needs no Accessibility permission —
/// macOS only guards the keyboard that way.
final class MouseButtonMonitor: HotkeyMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [HotkeyBinding] = []
    private var trigger: (@Sendable (HotkeyAction) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    @discardableResult
    func rebind(
        _ bindings: [HotkeyBinding],
        onTrigger: @escaping @Sendable (HotkeyAction) -> Void
    ) -> [HotkeyBinding] {
        lock.lock()
        self.bindings = bindings
        self.trigger = onTrigger
        lock.unlock()

        if bindings.isEmpty {
            removeMonitors()
        } else {
            installMonitors()
        }
        return []            // the system does not refuse these
    }

    func unbindAll() {
        lock.lock()
        bindings = []
        trigger = nil
        lock.unlock()
        removeMonitors()
    }

    private func installMonitors() {
        // AppKit's monitor API is main-thread business, and rebinding can be
        // called from anywhere.
        MainActor.assumeIsolatedOrHop { [self] in
            guard globalMonitor == nil, localMonitor == nil else { return }

            // `.otherMouseDown` and nothing else. Watching the left or right
            // button would mean a shortcut could be bound to clicking, and the
            // user would have no way to click anything again.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) {
                [weak self] event in
                self?.handle(button: event.buttonNumber, flags: event.modifierFlags)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) {
                [weak self] event in
                let handled = self?.handle(
                    button: event.buttonNumber, flags: event.modifierFlags) ?? false
                // Swallowed when it was ours, so a middle click bound to
                // dictation does not also do whatever it would have done.
                return handled ? nil : event
            }
        }
    }

    private func removeMonitors() {
        MainActor.assumeIsolatedOrHop { [self] in
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
        }
    }

    @discardableResult
    private func handle(button: Int, flags: NSEvent.ModifierFlags) -> Bool {
        let pressed = KeyCombination.mouseButton(button, modifiers: flags.asCombinationModifiers)

        lock.lock()
        let action = bindings.first { $0.combination == pressed }?.action
        let trigger = self.trigger
        lock.unlock()

        guard let action, let trigger else { return false }
        trigger(action)
        return true
    }
}

extension NSEvent.ModifierFlags {
    /// Only the four that matter, and only from
    /// `deviceIndependentFlagsMask` — the raw flags carry which physical key was
    /// used and whether caps lock is on, so comparing them directly would make
    /// the left Option key a different shortcut from the right one.
    public var asCombinationModifiers: KeyCombination.Modifiers {
        var modifiers: KeyCombination.Modifiers = []
        let flags = intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

extension MainActor {
    /// Runs the work on the main actor, now if that is where we already are.
    ///
    /// The synchronous path matters: `rebind` is not async, and hopping
    /// unconditionally would install the monitors after it has returned — so a
    /// button pressed in the meantime would be missed.
    static func assumeIsolatedOrHop(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}
