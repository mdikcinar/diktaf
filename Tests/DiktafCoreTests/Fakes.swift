import Foundation
import Synchronization
@testable import DiktafCore

/// What the fakes were asked to do, in the order they were asked.
///
/// Order is not a detail here. Restoring the keyboard after the paste instead of
/// before it produces a dictation that works when the application happens to be
/// frontmost and fails otherwise, which is the kind of bug that takes a day.
final class Journal: Sendable {
    private let entries = Mutex<[String]>([])

    func record(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }

    var all: [String] { entries.withLock { $0 } }

    func indexOf(_ entry: String) -> Int? { all.firstIndex(of: entry) }
}

/// Something a fake can be made to wait on, so a test can hold the session in
/// one state and look at it.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

/// Something a test can raise from inside a task and wait for outside it.
final class Flag: Sendable {
    private let raised = Mutex(false)

    func raise() { raised.withLock { $0 = true } }

    var isRaised: Bool { raised.withLock { $0 } }
}

/// A clock that moves on a second every time it is read, so each timestamp
/// says which reading took it.
final class TickingClock: Sendable {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let readings = Mutex(0)

    func now() -> Date {
        let reading = readings.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        return at(reading)
    }

    /// What the clock said on that reading, counting from zero.
    func at(_ reading: Int) -> Date {
        start.addingTimeInterval(TimeInterval(reading))
    }
}

// MARK: - Transcriber

/// Yields a scripted sequence, then ends the stream when it is stopped.
///
/// The stream deliberately ends only on `stop()`, the way a real recogniser
/// does, so the session's "stopping is not the same as having the transcript"
/// path is the one under test.
final class FakeTranscriber: Transcriber {
    private struct State {
        var continuation: AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation?
        var startCount = 0
        var stopCount = 0
        var cancelCount = 0
    }

    private let updates: [TranscriptUpdate]
    private let startFailure: (any Error)?
    private let failOnStop: (any Error)?
    private let startGate: Gate?
    private let stopGate: Gate?
    private let cancelDelay: Duration?
    private let state = Mutex(State())
    private let journal: Journal?

    init(
        updates: [TranscriptUpdate] = [],
        startFailure: (any Error)? = nil,
        failOnStop: (any Error)? = nil,
        startGate: Gate? = nil,
        stopGate: Gate? = nil,
        cancelDelay: Duration? = nil,
        journal: Journal? = nil
    ) {
        self.updates = updates
        self.startFailure = startFailure
        self.failOnStop = failOnStop
        self.startGate = startGate
        self.stopGate = stopGate
        self.cancelDelay = cancelDelay
        self.journal = journal
    }

    var startCount: Int { state.withLock { $0.startCount } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var cancelCount: Int { state.withLock { $0.cancelCount } }

    func start() async throws -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        journal?.record("transcriber.start")
        state.withLock { $0.startCount += 1 }
        // Held here, the recogniser is still loading and the session is still
        // idle — the window a second press or a cancel can land in.
        await startGate?.wait()
        if let startFailure { throw startFailure }

        let (stream, continuation) = AsyncThrowingStream
            .makeStream(of: TranscriptUpdate.self, throwing: (any Error).self)
        state.withLock { $0.continuation = continuation }
        for update in updates { continuation.yield(update) }
        return stream
    }

    func stop() async throws {
        journal?.record("transcriber.stop")
        state.withLock { $0.stopCount += 1 }
        // Held here, a real recogniser is still committing to the last words and
        // the session is sitting in `.settling` — which is where a test that
        // wants to look at a busy session can catch it.
        await stopGate?.wait()
        if let failOnStop {
            finish(throwing: failOnStop)
            throw failOnStop
        }
        finish(throwing: nil)
    }

    func cancel() async {
        journal?.record("transcriber.cancel")
        state.withLock { $0.cancelCount += 1 }
        // A real recogniser takes a moment to wind down, and a session that is
        // still half-cancelled during that moment has time to deliver anyway.
        if let cancelDelay { try? await Task.sleep(for: cancelDelay) }
        finish(throwing: CancellationError())
        journal?.record("transcriber.cancelled")
    }

    /// Ends the stream the way a recogniser losing its microphone would: on its
    /// own, with nobody having asked it to stop.
    func endUnprompted(throwing error: (any Error)? = nil) {
        finish(throwing: error)
    }

    private func finish(throwing error: (any Error)?) {
        let continuation = state.withLock { state -> AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish(throwing: error)
    }
}

// MARK: - Refiner

final class FakeRefiner: TextRefiner {
    enum Behaviour: Sendable {
        case cleaned(String)
        /// Replies with the text it was given, wrapped, so a test can prove the
        /// cleaned version is what was delivered.
        case echoingWrapped
        case failing(RefinementFailure)
        /// Never returns, so the deadline is what ends it.
        case hanging
        /// Replies once the gate opens, and not before: cancelling it does
        /// nothing, the way a subprocess that is not listening behaves.
        case held(Gate, reply: String)
    }

    private let behaviour: Behaviour
    private let journal: Journal?
    private let seen = Mutex<[(text: String, instruction: String)]>([])

    init(_ behaviour: Behaviour, journal: Journal? = nil) {
        self.behaviour = behaviour
        self.journal = journal
    }

    var calls: [(text: String, instruction: String)] { seen.withLock { $0 } }

    func refine(text: String, instruction: String) async throws -> String {
        journal?.record("refiner.refine")
        seen.withLock { $0.append((text, instruction)) }
        switch behaviour {
        case .cleaned(let reply): return reply
        case .echoingWrapped: return "«\(text)»"
        case .failing(let error): throw error
        case .hanging:
            // Long enough that the injected clock always wins, and cancellable
            // so the losing branch does not outlive the test.
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                journal?.record("refiner.cancelled")
                throw error
            }
            return text
        case .held(let gate, let reply):
            await gate.wait()
            return reply
        }
    }
}

// MARK: - Delivery

final class RecordingClipboard: Clipboard {
    private let stored = Mutex<String?>(nil)
    private let journal: Journal?

    init(journal: Journal? = nil) { self.journal = journal }

    func text() -> String? { stored.withLock { $0 } }

    func setText(_ text: String) {
        journal?.record("clipboard.set")
        stored.withLock { $0 = text }
    }
}

final class RecordingKeyboard: KeyboardSender {
    private let failure: (any Error)?
    private let journal: Journal?
    private let typed = Mutex<[String]>([])
    private let pastes = Mutex(0)

    init(failure: (any Error)? = nil, journal: Journal? = nil) {
        self.failure = failure
        self.journal = journal
    }

    var pasteCount: Int { pastes.withLock { $0 } }
    var typedText: [String] { typed.withLock { $0 } }

    func paste() throws {
        journal?.record("keyboard.paste")
        pastes.withLock { $0 += 1 }
        if let failure { throw failure }
    }

    func type(_ text: String) throws {
        journal?.record("keyboard.type")
        typed.withLock { $0.append(text) }
        if let failure { throw failure }
    }
}

final class FakeFocusGuard: FocusGuard {
    private let journal: Journal?
    private let counts = Mutex((remembered: 0, restored: 0))

    init(journal: Journal? = nil) { self.journal = journal }

    var remembered: Int { counts.withLock { $0.remembered } }
    var restored: Int { counts.withLock { $0.restored } }

    func remember() {
        journal?.record("focus.remember")
        counts.withLock { $0.remembered += 1 }
    }

    func restore() {
        journal?.record("focus.restore")
        counts.withLock { $0.restored += 1 }
    }
}

// MARK: - Settings

/// Settings that are held on one particular read, so a test can catch the
/// session waiting for them.
final class HeldSettings: Sendable {
    private let settings: Settings
    private let gate: Gate
    private let heldRead: Int
    private let count = Mutex(0)

    init(_ settings: Settings = .defaults, holdingRead heldRead: Int, gate: Gate) {
        self.settings = settings
        self.gate = gate
        self.heldRead = heldRead
    }

    var reads: Int { count.withLock { $0 } }

    func read() async -> Settings {
        let read = count.withLock { count -> Int in
            count += 1
            return count
        }
        if read == heldRead { await gate.wait() }
        return settings
    }
}

final class InMemorySettingsStorage: SettingsStorage {
    private let bytes = Mutex<Data?>(nil)
    private let saveFailure: (any Error)?
    private let loadFailure: (any Error)?

    init(
        initial: Data? = nil,
        loadFailure: (any Error)? = nil,
        saveFailure: (any Error)? = nil
    ) {
        self.bytes.withLock { $0 = initial }
        self.loadFailure = loadFailure
        self.saveFailure = saveFailure
    }

    var stored: Data? { bytes.withLock { $0 } }

    func load() throws -> Data? {
        if let loadFailure { throw loadFailure }
        return bytes.withLock { $0 }
    }

    func save(_ data: Data) throws {
        if let saveFailure { throw saveFailure }
        bytes.withLock { $0 = data }
    }
}

// MARK: - Agent

final class FakeAgentRunner: AgentRunner {
    enum Behaviour: Sendable {
        case replying(text: String, sessionID: String?)
        case failing(String)
        /// Says that the session it was asked to resume is gone.
        case expiring
        /// Replies once the gate opens, so a test can act while it waits.
        case held(Gate, text: String, sessionID: String?)
    }

    struct Call: Sendable, Equatable {
        let prompt: String
        let resuming: String?
    }

    /// One behaviour per call, the last repeated once the script runs out.
    private let script: [Behaviour]
    private let available: Bool
    private let seen = Mutex<[Call]>([])

    convenience init(_ behaviour: Behaviour, available: Bool = true) {
        self.init(script: [behaviour], available: available)
    }

    init(script: [Behaviour], available: Bool = true) {
        self.script = script
        self.available = available
    }

    var calls: [Call] { seen.withLock { $0 } }

    func isAvailable() async -> Bool { available }

    func run(prompt: String, resuming sessionID: String?) async throws -> AgentReply {
        let index = seen.withLock { calls -> Int in
            calls.append(Call(prompt: prompt, resuming: sessionID))
            return calls.count - 1
        }
        guard let behaviour = script.indices.contains(index) ? script[index] : script.last else {
            throw RefinementFailure.agentFailed("nothing scripted")
        }
        switch behaviour {
        case .replying(let text, let id):
            return AgentReply(text: text, sessionID: id)
        case .failing(let message):
            throw RefinementFailure.agentFailed(message)
        case .expiring:
            throw FakeSessionExpired()
        case .held(let gate, let text, let id):
            await gate.wait()
            return AgentReply(text: text, sessionID: id)
        }
    }
}

/// What `FakeAgentRunner` throws for a session that has gone, standing in for
/// the adapter's own error, which the domain cannot see.
struct FakeSessionExpired: Error, Equatable {}

// MARK: - Waiting

/// Waits for something the session does on a task of its own.
///
/// Polling rather than a sleep of a fixed length: the tests stay fast when
/// everything works and still fail rather than hang when something does not.
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw WaitTimeout(description: description)
}

struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}
