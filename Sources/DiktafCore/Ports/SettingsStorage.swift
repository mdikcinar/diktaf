import Foundation

/// Where the settings live between runs.
///
/// Bytes rather than a `Settings`, so that the encoding, the migration of an
/// older file and the decision to keep going with defaults when the file is
/// unreadable all stay in the domain — and so that a test can hold the whole
/// store in memory.
public protocol SettingsStorage: Sendable {
    /// The stored bytes, or nil on the first ever run.
    func load() throws -> Data?

    /// Replaces them. Must not leave a half-written file behind on failure:
    /// settings that fail to save are recoverable, settings that are corrupted
    /// are not.
    func save(_ data: Data) throws
}
