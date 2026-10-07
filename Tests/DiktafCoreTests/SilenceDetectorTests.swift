import Foundation
import Testing
@testable import DiktafCore

/// Levels from a MacBook Pro microphone at an input volume of 27: the room at
/// −78 dBFS and somebody talking quietly at −60, which a fixed −40 line took for
/// silence.
@Suite("Silence detector")
struct SilenceDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let room: Float = -78
    private let quietSpeech: Float = -60

    /// Feeds one reading every 50 ms, the rate the app polls at.
    private func feed(_ detector: inout SilenceDetector, _ decibels: Float,
                      for seconds: Double, from offset: inout Double) {
        let steps = Int((seconds / 0.05).rounded())
        for _ in 0..<steps {
            offset += 0.05
            detector.observe(decibels: decibels, at: start.addingTimeInterval(offset))
        }
    }

    @Test("quiet before the first word is not the end of anything")
    func waitsForWords() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 10, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }

    @Test("a click before the first word does not start the count")
    func ignoresAClick() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 1, from: &t)
        feed(&detector, -20, for: 0.5, from: &t)
        feed(&detector, room, for: 5, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }

    @Test("quiet after speech is counted from the last of it")
    func countsFromTheLastWord() throws {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 1, from: &t)
        detector.heardWords()
        feed(&detector, quietSpeech, for: 1.5, from: &t)
        feed(&detector, room, for: 2, from: &t)
        let quiet = try #require(detector.quiet(at: start.addingTimeInterval(t)))
        #expect(abs(quiet - 1.95) < 0.06)
    }

    @Test("a quiet speaker is still speaking")
    func hearsAQuietSpeaker() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 1, from: &t)
        detector.heardWords()
        feed(&detector, quietSpeech, for: 8, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }

    @Test("speaking again starts the count over")
    func resetsOnSpeech() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 1, from: &t)
        detector.heardWords()
        feed(&detector, quietSpeech, for: 1, from: &t)
        feed(&detector, room, for: 1.5, from: &t)
        feed(&detector, quietSpeech, for: 0.2, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }

    @Test("new words count as talking whatever the level says")
    func resetsOnWords() throws {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 1, from: &t)
        detector.heardWords()
        feed(&detector, room, for: 3, from: &t)
        detector.heardWords()
        feed(&detector, room, for: 0.5, from: &t)
        let quiet = try #require(detector.quiet(at: start.addingTimeInterval(t)))
        #expect(quiet < 0.5)
    }

    @Test("the line follows the room, at any input volume", arguments: [-78, -60, -45] as [Float])
    func followsTheRoom(_ room: Float) throws {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 1, from: &t)
        detector.heardWords()
        feed(&detector, room + 20, for: 2, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
        feed(&detector, room + 3, for: 2, from: &t)
        let quiet = try #require(detector.quiet(at: start.addingTimeInterval(t)))
        #expect(abs(quiet - 1.95) < 0.06)
    }

    @Test("a dropout to digital silence does not move the room")
    func ignoresADropout() throws {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, room, for: 0.5, from: &t)
        feed(&detector, -.infinity, for: 0.05, from: &t)
        feed(&detector, room, for: 0.5, from: &t)
        detector.heardWords()
        feed(&detector, room, for: 2, from: &t)
        #expect(detector.room == room)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) != nil)
    }
}
