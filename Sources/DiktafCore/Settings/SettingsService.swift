import Foundation

/// The settings, loaded once and written back on every change.
///
/// An actor because the hotkey handler, the settings window and the dictation
/// session all read this, and two of them can write it.
public actor SettingsService {
    private let storage: any SettingsStorage
    private var current: Settings

    /// Why the stored settings could not be read, if they could not be.
    ///
    /// Kept rather than thrown, and the file is left exactly where it is: a
    /// user whose settings will not parse gets a working application with
    /// defaults and a line in the window telling them so, which is recoverable.
    /// Silently overwriting the file with defaults is not.
    public private(set) var loadFailure: String?

    public init(storage: any SettingsStorage) {
        self.storage = storage
        self.current = .defaults

        do {
            if let data = try storage.load() {
                self.current = try JSONDecoder().decode(Settings.self, from: data)
            }
        } catch {
            self.loadFailure = String(describing: error)
        }
    }

    public var settings: Settings { current }

    /// Applies a change and writes it back.
    ///
    /// The in-memory value is updated even when the write fails, so that the
    /// window shows what the user just chose rather than silently reverting;
    /// the failure is thrown for them to see.
    public func update(_ change: @Sendable (inout Settings) -> Void) throws {
        var draft = current
        change(&draft)
        guard draft != current else { return }
        current = draft
        try write(draft)
    }

    /// Puts the stored file back to defaults, having been asked to.
    public func reset() throws {
        current = .defaults
        loadFailure = nil
        try write(current)
    }

    private func write(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try storage.save(try encoder.encode(settings))
    }
}
