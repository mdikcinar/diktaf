import Foundation

/// The settings as a file on disk.
///
/// In Core rather than in the platform adapters because there is nothing
/// macOS-specific about it: a path and two Foundation calls, both of which work
/// wherever Foundation does.
public struct FileSettingsStorage: SettingsStorage {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/.config/diktaf/settings.json`, which is where a person would look for
    /// it — and which they can edit, back up and put under version control.
    public static func inUserConfiguration(
        home: URL = URL(filePath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FileSettingsStorage {
        let base = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
            ?? home.appending(path: ".config")
        return FileSettingsStorage(
            url: base.appending(path: "diktaf/settings.json"))
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Written beside the target and moved into place.
    ///
    /// A direct write that fails halfway leaves a file that is neither the old
    /// settings nor the new ones, and the next run cannot read it. A rename is
    /// atomic, so the file on disk is always one whole version or the other.
    public func save(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let scratch = directory.appending(path: ".\(url.lastPathComponent).new")
        try data.write(to: scratch, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
    }
}
