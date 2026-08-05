import Foundation

/// Speech turned into text by whatever the machine already has.
///
/// The two-part update is not a convenience: it is how on-device recognisers
/// actually work. Words arrive as a guess that is revised for a while and then
/// committed to, and a dictation indicator that shows only committed text lags
/// visibly behind the speaker. So both halves are carried, and the caller
/// decides which of them to show and which to keep.
public protocol Transcriber: Sendable {
    /// Begins listening and yields an update whenever the text changes.
    ///
    /// The stream finishes after `stop()`, once the recogniser has committed to
    /// the last of what it heard — which is a moment later than the audio ended,
    /// and the reason stopping is not the same as having the transcript.
    func start() async throws -> AsyncThrowingStream<TranscriptUpdate, any Error>

    /// Stops the audio and asks for the remaining words. The stream ends by
    /// itself once they arrive.
    func stop() async throws

    /// Drops everything, including whatever has been recognised so far. The
    /// stream finishes without yielding again.
    func cancel() async
}

/// What the recogniser thinks it has heard, in the two states it thinks it.
public struct TranscriptUpdate: Sendable, Equatable {
    /// Text the recogniser has committed to and will not revise.
    public let settled: String

    /// The tail it is still revising. Empty by the time the stream ends.
    public let volatile: String

    public init(settled: String, volatile: String = "") {
        self.settled = settled
        self.volatile = volatile
    }

    /// Everything heard so far, which is what an indicator shows.
    public var text: String {
        volatile.isEmpty ? settled : "\(settled)\(settled.isEmpty ? "" : " ")\(volatile)"
    }
}

/// Why a transcription could not happen, in the caller's terms rather than the
/// framework's. An adapter maps its own failures onto these.
public enum TranscriptionFailure: Error, Sendable, Equatable {
    /// The system has no on-device model for this language.
    case languageUnavailable(String)
    /// A model has to be downloaded before dictation can start.
    case modelNotInstalled(String)
    /// Recording or recognition was refused in the system settings.
    case notPermitted(PermissionKind)
    /// There is no microphone, or the one there is went away mid-recording.
    case audioUnavailable(String)
    /// Anything the adapter could not place, kept as text rather than lost.
    case underlying(String)
}
