import Foundation

/// Which recogniser turns the audio into text.
///
/// A choice rather than a decision made once for everybody, because the two are
/// good at different things and neither is better on every axis:
///
/// * `.system` is Apple's own dictation model. It costs nothing to keep, starts
///   instantly, follows the language you set, and is the model the rest of macOS
///   uses. It is also the one that hears "Firebase CLI" as three Turkish words,
///   because its language model does not expect the term.
/// * `.whisper` is Whisper large-v3-turbo as Core ML, on this Mac. It knows the
///   vocabulary of people who talk about software, in every language it
///   supports, which is the whole reason for offering it. It costs a download
///   measured in hundreds of megabytes, a few seconds to load the first time,
///   and it transcribes in passes rather than word by word — so the indicator
///   shows a rougher preview than the system recogniser does.
///
/// Nothing here knows how either one works. This is the name of a choice; the
/// app is what turns it into an adapter.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    /// The speech recogniser built into macOS. No download, no dependency.
    case system

    /// Whisper, run locally through Core ML.
    case whisper
}
