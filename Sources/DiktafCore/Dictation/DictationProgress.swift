import Foundation

/// What has happened so far in the current dictation, for an interface that
/// shows its work.
///
/// `DictationState` says where the session is; this says how it got there —
/// when each step happened, what the recogniser heard, and what became of the
/// cleanup. Each field stays nil until its step has happened.
public struct DictationProgress: Sendable, Equatable {
    public var destination: DictationDestination

    /// When recording began: after the transcriber started, not when the key
    /// was pressed.
    public var startedAt: Date

    /// When the user stopped, or the stream ended by itself.
    public var recordingEndedAt: Date?

    /// When the recogniser had committed to the last words.
    public var transcriptReadyAt: Date?

    /// What the recogniser heard, before any cleanup.
    public var rawTranscript: String?

    /// Nil until cleanup is attempted or skipped. A dictation for the agent is
    /// never cleaned up, so for one of those it stays nil.
    public var cleanup: CleanupProgress?

    /// How the text is going into the window, once that has been decided.
    public var delivery: DeliveryMode?

    /// When the text arrived.
    public var deliveredAt: Date?

    public init(
        destination: DictationDestination,
        startedAt: Date,
        recordingEndedAt: Date? = nil,
        transcriptReadyAt: Date? = nil,
        rawTranscript: String? = nil,
        cleanup: CleanupProgress? = nil,
        delivery: DeliveryMode? = nil,
        deliveredAt: Date? = nil
    ) {
        self.destination = destination
        self.startedAt = startedAt
        self.recordingEndedAt = recordingEndedAt
        self.transcriptReadyAt = transcriptReadyAt
        self.rawTranscript = rawTranscript
        self.cleanup = cleanup
        self.delivery = delivery
        self.deliveredAt = deliveredAt
    }
}

/// The cleanup step of one dictation.
public struct CleanupProgress: Sendable, Equatable {
    /// From the settings the cleanup was started with, which may no longer be
    /// what the settings say.
    public var engine: CleanupEngine
    public var startedAt: Date

    /// How long it was allowed before the raw transcript is used instead.
    public var deadlineSeconds: Int
    public var outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case running
        case cleaned(String, finishedAt: Date)

        /// The raw transcript was used instead: the cleanup timed out, failed,
        /// or replied with nothing. The reason is written for a person.
        case fellBack(reason: String, finishedAt: Date)

        case skipped(SkipReason)
    }

    public enum SkipReason: String, Sendable, Equatable {
        /// Cleanup is switched off.
        case disabled
        /// No rule and no extra instruction is in force, so there is nothing to ask for.
        case noRules
        /// There is no agent to ask.
        case noRefiner
    }

    public init(engine: CleanupEngine, startedAt: Date, deadlineSeconds: Int, outcome: Outcome) {
        self.engine = engine
        self.startedAt = startedAt
        self.deadlineSeconds = deadlineSeconds
        self.outcome = outcome
    }
}
