import Foundation

/// Where a dictation is headed, decided when it starts.
public enum DictationDestination: String, Sendable, Equatable, Codable {
    /// The window the user was typing in.
    case insertion
    /// The agent, as a question. Nothing is pasted.
    case agent
}

/// What the session is doing, and the only thing the interface needs to know.
public enum DictationState: Sendable, Equatable {
    case idle

    /// Listening. The text is what has been heard so far, for the indicator to
    /// show — a user who cannot see the words arriving has no way to tell
    /// dictation from a dead microphone.
    case recording(text: String, destination: DictationDestination)

    /// Stopped, waiting for the recogniser to commit to the last words. A state
    /// of its own because it is not instantaneous, and somebody who has just
    /// pressed stop deserves to see that something is happening.
    case settling

    /// With the agent, being cleaned up.
    case refining

    /// On the clipboard, going into the window.
    case delivering

    /// Something went wrong, and this is what to tell the user. The next toggle
    /// starts a new dictation; nothing clears this by itself, because a message
    /// that disappears before it is read might as well not have been shown.
    case failed(message: String)

    /// Whether a new dictation can be started right now.
    public var isBusy: Bool {
        switch self {
        case .idle, .failed: false
        case .recording, .settling, .refining, .delivering: true
        }
    }
}

/// Everything the session tells the world.
///
/// One stream rather than two, because state and remarks have to arrive in
/// order relative to each other: "cleanup failed, so this is the raw
/// transcript" makes sense before the delivery it explains and nonsense after
/// some later dictation.
public enum DictationEvent: Sendable, Equatable {
    case state(DictationState)

    /// Something the user should know about a dictation that nevertheless
    /// worked. The cleanup that timed out, the raw transcript delivered
    /// instead. Not an error: the text arrived.
    case notice(String)

    /// A finished dictation whose destination was the agent, handed over rather
    /// than pasted.
    case agentPrompt(String)
}
