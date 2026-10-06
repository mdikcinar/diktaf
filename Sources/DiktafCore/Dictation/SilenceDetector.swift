import Foundation

/// Tells when a dictation has gone quiet, from the input level the recogniser
/// in use reports.
///
/// Quiet only counts once the speaker has started: an open microphone before
/// the first word is somebody gathering their thoughts, not somebody who has
/// finished.
public struct SilenceDetector: Sendable {
    /// −40 dBFS on the meter's 0…1 scale, the same line the Whisper adapter
    /// draws between speech and the room.
    public static let speechLevel: Float = 0.25

    /// How much speech there has to have been before quiet means "done". Less
    /// than this is a cough or a click.
    public static let minimumSpeech: TimeInterval = 0.3

    private var speech: TimeInterval = 0
    private var lastObservation: Date?

    /// When the current quiet began, or nil while somebody is talking or has
    /// not started yet.
    public private(set) var quietSince: Date?

    public init() {}

    public mutating func observe(level: Float, at now: Date) {
        let step = lastObservation.map { max(0, now.timeIntervalSince($0)) } ?? 0
        lastObservation = now
        if level >= Self.speechLevel {
            speech += step
            quietSince = nil
        } else if speech >= Self.minimumSpeech, quietSince == nil {
            quietSince = now
        }
    }

    /// How long it has been quiet since the speaker last said something, or
    /// nil if they are talking or have not started.
    public func quiet(at now: Date) -> TimeInterval? {
        quietSince.map { now.timeIntervalSince($0) }
    }
}
