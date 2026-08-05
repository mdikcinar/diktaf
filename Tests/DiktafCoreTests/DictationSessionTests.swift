import Foundation
import Synchronization
import Testing
@testable import DiktafCore

/// A Mutex cannot be copied, so the draining task and the log share this rather
/// than each holding one.
private final class EventBox: Sendable {
    let events = Mutex<[DictationEvent]>([])
}

/// Everything the session told the world, in order.
final class EventLog: Sendable {
    private let box: EventBox
    private let pump: Task<Void, Never>

    init(_ stream: AsyncStream<DictationEvent>) {
        let box = EventBox()
        self.box = box
        self.pump = Task {
            for await event in stream { box.events.withLock { $0.append(event) } }
        }
    }

    deinit { pump.cancel() }

    var all: [DictationEvent] { box.events.withLock { $0 } }

    var states: [DictationState] {
        all.compactMap { if case .state(let state) = $0 { state } else { nil } }
    }

    var notices: [String] {
        all.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }

    var agentPrompts: [String] {
        all.compactMap { if case .agentPrompt(let prompt) = $0 { prompt } else { nil } }
    }

    /// Waits for the drain task to catch up, then asserts.
    ///
    /// The events are handed over synchronously but read on a task of its own,
    /// so asserting the instant after an action races it. Waiting first and
    /// asserting after keeps the diff on failure and takes the flake out.
    func expectPhases(
        _ expected: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        try? await waitUntil("phases") { self.phases == expected }
        #expect(phases == expected, sourceLocation: sourceLocation)
    }

    func expectNotice(
        containing needle: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        try? await waitUntil("a notice mentioning \(needle)") {
            self.notices.contains { $0.contains(needle) }
        }
        #expect(notices.contains { $0.contains(needle) },
                "notices were \(notices)", sourceLocation: sourceLocation)
    }

    func expectAgentPrompts(
        _ expected: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        try? await waitUntil("agent prompts") { self.agentPrompts == expected }
        #expect(agentPrompts == expected, sourceLocation: sourceLocation)
    }

    func expectNoNotices(sourceLocation: SourceLocation = #_sourceLocation) async {
        // Nothing to wait for, so give the drain task a moment to prove there is
        // nothing rather than asserting on an empty log that has not filled yet.
        try? await waitUntil("the log to fill") { !self.states.isEmpty }
        await Task.yield()
        #expect(notices.isEmpty, sourceLocation: sourceLocation)
    }

    /// The states with the live-text updates collapsed away, which is what a
    /// test about the flow cares about.
    var phases: [String] {
        var names: [String] = []
        for state in states {
            let name = switch state {
            case .idle: "idle"
            case .recording: "recording"
            case .settling: "settling"
            case .refining: "refining"
            case .delivering: "delivering"
            case .failed: "failed"
            }
            if names.last != name { names.append(name) }
        }
        return names
    }
}

/// A session and the fakes underneath it.
private struct Harness {
    let transcriber: FakeTranscriber
    let refiner: FakeRefiner?
    let clipboard: RecordingClipboard
    let keyboard: RecordingKeyboard
    let focus: FakeFocusGuard
    let journal: Journal
    let session: DictationSession

    init(
        updates: [TranscriptUpdate] = [TranscriptUpdate(settled: "hello there", volatile: "")],
        transcriber: FakeTranscriber? = nil,
        refiner: FakeRefiner? = FakeRefiner(.cleaned("Hello there.")),
        keyboard: RecordingKeyboard? = nil,
        settings: Settings = .defaults
    ) {
        let journal = Journal()
        self.journal = journal
        self.transcriber = transcriber ?? FakeTranscriber(updates: updates, journal: journal)
        self.refiner = refiner
        self.clipboard = RecordingClipboard(journal: journal)
        self.keyboard = keyboard ?? RecordingKeyboard(journal: journal)
        self.focus = FakeFocusGuard(journal: journal)

        // Instant, so a twenty-second deadline costs the test nothing while the
        // race it is there to settle is still the real one.
        self.session = DictationSession(
            transcriber: self.transcriber,
            refiner: refiner,
            clipboard: self.clipboard,
            keyboard: self.keyboard,
            focus: self.focus,
            settings: { settings },
            sleep: { _ in await Task.yield() }
        )
    }

    func log() async -> EventLog { EventLog(await session.events()) }
}

@Suite("Dictation session")
struct DictationSessionTests {

    // MARK: - The path everything else is a deviation from

    @Test("a dictation is recorded, cleaned up, put on the clipboard and pasted")
    func happyPath() async throws {
        let harness = Harness()
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "Hello there.")
        #expect(harness.keyboard.pasteCount == 1)
        #expect(await harness.session.currentState == .idle)
        await log.expectPhases(["idle", "recording", "settling", "refining", "delivering", "idle"])
        #expect(harness.refiner?.calls.first?.text == "hello there")
    }

    @Test("the words show up while they are being said")
    func showsLiveText() async throws {
        let harness = Harness(updates: [
            TranscriptUpdate(settled: "hello", volatile: "the"),
            TranscriptUpdate(settled: "hello there", volatile: ""),
        ])

        await harness.session.toggle()

        try await waitUntil("the live text reaches the state") {
            if case .recording(let text, _) = await harness.session.currentState {
                return text == "hello there"
            }
            return false
        }
        await harness.session.cancel()
    }

    @Test("the volatile tail is shown as part of the text")
    func showsVolatileTail() {
        let update = TranscriptUpdate(settled: "hello", volatile: "there")

        #expect(update.text == "hello there")
        #expect(TranscriptUpdate(settled: "", volatile: "hi").text == "hi")
        #expect(TranscriptUpdate(settled: "hi", volatile: "").text == "hi")
    }

    // MARK: - Cleanup, and the four ways it can let you down

    @Test("with cleanup off the agent is never asked and the raw text is pasted")
    func skipsCleanupWhenOff() async throws {
        var settings = Settings.defaults
        settings.cleanupEnabled = false
        let harness = Harness(settings: settings)
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "hello there")
        #expect(harness.refiner?.calls.isEmpty == true)
        await log.expectPhases(["idle", "recording", "settling", "delivering", "idle"])
    }

    @Test("with no rules left there is nothing to ask for")
    func skipsCleanupWithoutRules() async throws {
        var settings = Settings.defaults
        settings.rules = CleanupRuleSet()
        let harness = Harness(settings: settings)

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "hello there")
        #expect(harness.refiner?.calls.isEmpty == true)
    }

    @Test("with no agent installed at all the raw text still arrives")
    func worksWithoutARefiner() async throws {
        let harness = Harness(refiner: nil)

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "hello there")
        #expect(harness.keyboard.pasteCount == 1)
    }

    /// The rule the whole design turns on: a dictation that arrives uncleaned is
    /// a small disappointment, one that disappears is a reason to stop using
    /// this.
    @Test("a cleanup that fails delivers the raw transcript and says why")
    func fallsBackWhenCleanupFails() async throws {
        let harness = Harness(refiner: FakeRefiner(.failing(.agentFailed("exit 1"))))
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "hello there")
        #expect(harness.keyboard.pasteCount == 1)
        #expect(await harness.session.currentState == .idle)
        await log.expectNotice(containing: "raw transcript")
    }

    @Test("a cleanup that never returns is abandoned at the deadline")
    func fallsBackWhenCleanupHangs() async throws {
        var settings = Settings.defaults
        settings.refinerTimeoutSeconds = 7
        let harness = Harness(refiner: FakeRefiner(.hanging), settings: settings)
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "hello there")
        #expect(await harness.session.currentState == .idle)
        await log.expectNotice(containing: "7s")
    }

    @Test("an empty reply is not a cleaned-up transcript", arguments: ["", "   \n"])
    func fallsBackWhenCleanupSaysNothing(_ reply: String) async throws {
        let harness = Harness(refiner: FakeRefiner(.cleaned(reply)))
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "hello there")
        await log.expectNotice(containing: "nothing")
    }

    @Test("the cleaned text is trimmed before it is delivered")
    func trimsCleanedText() async throws {
        let harness = Harness(refiner: FakeRefiner(.cleaned("  Hello there.\n")))

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "Hello there.")
    }

    @Test("the instruction handed over is the one the rules build")
    func passesTheBuiltInstruction() async throws {
        var settings = Settings.defaults
        settings.language = "tr-TR"
        let harness = Harness(settings: settings)

        await harness.session.toggle()
        await harness.session.toggle()

        let instruction = try #require(harness.refiner?.calls.first?.instruction)
        #expect(instruction == settings.rules.instruction(language: "tr-TR"))
        #expect(instruction.contains("tr-TR"))
    }

    // MARK: - Delivery

    @Test("typing leaves the clipboard alone")
    func typingDoesNotTouchTheClipboard() async throws {
        var settings = Settings.defaults
        settings.delivery = .type
        let harness = Harness(settings: settings)

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == nil)
        #expect(harness.keyboard.typedText == ["Hello there."])
        #expect(harness.keyboard.pasteCount == 0)
    }

    @Test("clipboard-only stops at the clipboard")
    func clipboardOnlyPressesNothing() async throws {
        var settings = Settings.defaults
        settings.delivery = .clipboardOnly
        let harness = Harness(settings: settings)

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "Hello there.")
        #expect(harness.keyboard.pasteCount == 0)
        #expect(harness.keyboard.typedText.isEmpty)
    }

    /// The order that makes the difference between a dictation that works and
    /// one that works only when Diktaf happens to be frontmost.
    @Test("the keyboard is noted before anything is shown and handed back before the paste")
    func keepsTheKeyboardInOrder() async throws {
        let harness = Harness()

        await harness.session.toggle()
        await harness.session.toggle()

        let entries = harness.journal.all
        let remembered = try #require(entries.firstIndex(of: "focus.remember"))
        let started = try #require(entries.firstIndex(of: "transcriber.start"))
        let restored = try #require(entries.firstIndex(of: "focus.restore"))
        let pasted = try #require(entries.firstIndex(of: "keyboard.paste"))

        #expect(remembered < started, "noted before the indicator can steal it")
        #expect(restored < pasted, "handed back before the key is pressed")
        #expect(harness.focus.remembered == 1)
        #expect(harness.focus.restored == 1)
    }

    @Test("a paste that fails is reported, with the text still on the clipboard")
    func reportsPasteFailure() async throws {
        struct NotAllowed: Error {}
        let journal = Journal()
        let harness = Harness(keyboard: RecordingKeyboard(failure: NotAllowed(), journal: journal))

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "Hello there.")
        if case .failed = await harness.session.currentState {} else {
            Issue.record("a paste that threw should leave the session in .failed")
        }
    }

    // MARK: - Nothing to deliver

    @Test("a dictation with nothing in it ends quietly", arguments: [
        [TranscriptUpdate(settled: "", volatile: "")],
        [TranscriptUpdate(settled: "   ", volatile: "  ")],
        [],
    ])
    func deliversNothingForSilence(_ updates: [TranscriptUpdate]) async throws {
        let harness = Harness(updates: updates)
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == nil)
        #expect(harness.keyboard.pasteCount == 0)
        #expect(await harness.session.currentState == .idle)
        await log.expectNoNotices()
        await log.expectPhases(["idle", "recording", "settling", "idle"])
    }

    // MARK: - The agent

    @Test("a dictation for the agent is handed over, not pasted")
    func handsOverToTheAgent() async throws {
        let harness = Harness()
        let log = await harness.log()

        await harness.session.toggle(destination: .agent)
        await harness.session.toggle()

        await log.expectAgentPrompts(["hello there"])
        #expect(harness.clipboard.text() == nil)
        #expect(harness.keyboard.pasteCount == 0)
        #expect(await harness.session.currentState == .idle)
    }

    /// A question does not want its filler words taken out by a second agent
    /// before the first one reads it.
    @Test("a question is not cleaned up on its way to the agent")
    func doesNotCleanUpAgentPrompts() async throws {
        let harness = Harness()

        await harness.session.toggle(destination: .agent)
        await harness.session.toggle()

        #expect(harness.refiner?.calls.isEmpty == true)
    }

    // MARK: - Cancelling

    @Test("cancelling while recording delivers nothing")
    func cancelsWhileRecording() async throws {
        let harness = Harness()
        let log = await harness.log()

        await harness.session.toggle()
        await harness.session.cancel()

        #expect(harness.transcriber.cancelCount == 1)
        #expect(harness.transcriber.stopCount == 0)
        #expect(harness.clipboard.text() == nil)
        #expect(harness.keyboard.pasteCount == 0)
        #expect(await harness.session.currentState == .idle)
        await log.expectPhases(["idle", "recording", "idle"])
    }

    @Test("cancelling when there is nothing to cancel is not an error")
    func cancelsFromIdle() async throws {
        let harness = Harness()

        await harness.session.cancel()

        #expect(await harness.session.currentState == .idle)
        #expect(harness.transcriber.startCount == 0)
    }

    @Test("cancelling clears a failure that is still on screen")
    func cancelClearsFailure() async throws {
        struct Boom: Error {}
        let harness = Harness(transcriber: FakeTranscriber(startFailure: Boom()))

        await harness.session.toggle()
        if case .failed = await harness.session.currentState {} else {
            Issue.record("a transcriber that will not start should fail the dictation")
        }

        await harness.session.cancel()
        #expect(await harness.session.currentState == .idle)
    }

    @Test("the next dictation starts clean after one was cancelled")
    func startsCleanAfterCancel() async throws {
        let harness = Harness()

        await harness.session.toggle()
        await harness.session.cancel()
        await harness.session.toggle()
        await harness.session.toggle()

        #expect(harness.clipboard.text() == "Hello there.")
        #expect(harness.transcriber.startCount == 2)
    }

    // MARK: - Presses that arrive at the wrong moment

    /// The user pressed it because nothing had happened yet. Starting a second
    /// dictation on top of the first is never what they meant.
    @Test("a press during delivery is ignored rather than queued")
    func ignoresPressesWhileBusy() async throws {
        let gate = Gate()
        let harness = Harness(transcriber: FakeTranscriber(
            updates: [TranscriptUpdate(settled: "hello there", volatile: "")],
            stopGate: gate))

        await harness.session.toggle()
        let finishing = Task { await harness.session.toggle() }

        // Held in `.settling`: the recogniser has been asked to stop and has not
        // finished committing to the last words, which is exactly the window a
        // second press lands in.
        try await waitUntil("the session reaches settling") {
            await harness.session.currentState == .settling
        }
        await harness.session.toggle()          // the press to be ignored
        await gate.open()
        await finishing.value

        #expect(harness.transcriber.startCount == 1, "no second recording was started")
        #expect(harness.clipboard.text() == "Hello there.", "the first dictation still arrived")
    }

    // MARK: - When the hardware gives up

    @Test("a transcriber that will not start is reported")
    func reportsStartFailure() async throws {
        let harness = Harness(
            transcriber: FakeTranscriber(startFailure: TranscriptionFailure.notPermitted(.microphone)))
        let log = await harness.log()

        await harness.session.toggle()

        await log.expectPhases(["idle", "failed"])
        #expect(log.states.last == .failed(message: "Diktaf is not allowed to use the microphone."))
    }

    /// The microphone was unplugged. What it heard before that is still worth
    /// having, and waiting for last words that will never come would hang the
    /// dictation on the one path where the hardware has already failed.
    @Test("a stream that ends by itself finishes the dictation with what was heard")
    func finishesWhenTheStreamEndsUnprompted() async throws {
        let harness = Harness()

        await harness.session.toggle()
        try await waitUntil("the live text arrives") {
            if case .recording(let text, _) = await harness.session.currentState {
                return !text.isEmpty
            }
            return false
        }
        harness.transcriber.endUnprompted()

        try await waitUntil("the dictation completes") {
            await harness.session.currentState == .idle
        }
        #expect(harness.clipboard.text() == "Hello there.")
    }

    @Test("a stream that dies mid-recording is reported")
    func reportsStreamFailure() async throws {
        let harness = Harness()

        await harness.session.toggle()
        harness.transcriber.endUnprompted(
            throwing: TranscriptionFailure.audioUnavailable("device went away"))

        try await waitUntil("the failure reaches the state") {
            if case .failed = await harness.session.currentState { return true }
            return false
        }
        #expect(harness.clipboard.text() == nil)
    }

    // MARK: - Watching

    @Test("an interface that subscribes late is told the state straight away")
    func replaysCurrentState() async throws {
        let harness = Harness()
        await harness.session.toggle()

        let log = await harness.log()

        try await waitUntil("the first event arrives") { !log.all.isEmpty }
        if case .recording = log.states.first {} else {
            Issue.record("the first event should be the state as it is now")
        }
        await harness.session.cancel()
    }
}
