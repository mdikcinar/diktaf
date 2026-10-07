import Foundation

/// Tells when a dictation has gone quiet: the input back down at the room's own
/// level, and no new words from the recogniser.
///
/// Measured against the room rather than against a fixed line, because no fixed
/// line is right for every microphone. At a low input volume ordinary speech
/// arrives at −60 dBFS, and a −40 line heard it as silence and ended the
/// dictation while the speaker was still talking. The room is taken from this
/// dictation's own quietest stretches, so the line moves with the gain.
///
/// New words count as talking whatever the level says, which is the one sign of
/// a speaker no gain setting can hide.
///
/// Quiet only counts once the recogniser has heard a word: an open microphone
/// before that is somebody gathering their thoughts, not somebody who has
/// finished — and a key click is loud, but it is not a word.
public struct SilenceDetector: Sendable {
    /// How far above the room a reading has to be to count as somebody talking.
    /// Measured on a MacBook at a low input volume, soft speech sat 15 to 25 dB
    /// above the room and the room's own flicker within 6.
    public static let speechMargin: Float = 15

    /// The span readings are kept in, in dBFS, one bucket per decibel. A buffer
    /// of digital silence reads as −∞ and is kept as the bottom of it.
    private static let quietest: Float = -100

    private var buckets = [Int](repeating: 0, count: 101)
    private var readings = 0
    private var hasHeardWords = false

    /// When the current quiet began, or nil while somebody is talking or has
    /// not started yet.
    public private(set) var quietSince: Date?

    public init() {}

    /// The room, in dBFS: the level a tenth of this dictation's readings fall
    /// below. A percentile rather than the quietest reading, because one dropout
    /// to digital silence would otherwise put the room so low that its own
    /// noise counted as speech.
    public var room: Float? {
        guard readings > 0 else { return nil }
        var counted = 0
        for (index, count) in buckets.enumerated() {
            counted += count
            if counted * 10 >= readings { return Self.quietest + Float(index) }
        }
        return 0
    }

    public mutating func observe(decibels: Float, at now: Date) {
        let clamped = min(0, max(Self.quietest, decibels))
        buckets[Int((clamped - Self.quietest).rounded())] += 1
        readings += 1

        if let room, clamped >= room + Self.speechMargin {
            quietSince = nil
        } else if hasHeardWords, quietSince == nil {
            quietSince = now
        }
    }

    /// The recogniser has more words than it had.
    public mutating func heardWords() {
        hasHeardWords = true
        quietSince = nil
    }

    /// How long it has been quiet since the speaker last said something, or
    /// nil if they are talking or have not started.
    public func quiet(at now: Date) -> TimeInterval? {
        quietSince.map { now.timeIntervalSince($0) }
    }
}
