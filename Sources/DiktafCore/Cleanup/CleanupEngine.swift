import Foundation

/// Which agent cleans up a transcript.
///
/// Like `TranscriptionEngine`, this is the name of a choice and nothing more:
/// nothing here knows how either one is reached, and the app is what turns it
/// into a `TextRefiner`.
public enum CleanupEngine: String, Codable, Sendable, CaseIterable {
    /// A model served by Ollama on this Mac, named by `Settings.ollamaModel`.
    case ollama

    /// The `claude` command, with `Settings.cleanupModel` as its model.
    case claude
}
