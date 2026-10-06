import Foundation
import Testing
@testable import DiktafCore

@Suite("Silence detector")
struct SilenceDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    /// Feeds one level every 50 ms, the rate the app polls at.
    private func feed(_ detector: inout SilenceDetector, _ level: Float,
                      for seconds: Double, from offset: inout Double) {
        let steps = Int((seconds / 0.05).rounded())
        for _ in 0..<steps {
            offset += 0.05
            detector.observe(level: level, at: start.addingTimeInterval(offset))
        }
    }

    @Test("quiet before the first word is not the end of anything")
    func waitsForSpeech() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, 0.02, for: 10, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }

    @Test("quiet after speech is counted from the last word")
    func countsFromTheLastWord() throws {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, 0.7, for: 1.5, from: &t)
        feed(&detector, 0.05, for: 2, from: &t)
        let quiet = try #require(detector.quiet(at: start.addingTimeInterval(t)))
        #expect(abs(quiet - 1.95) < 0.06)
    }

    @Test("speaking again starts the count over")
    func resetsOnSpeech() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, 0.7, for: 1, from: &t)
        feed(&detector, 0.05, for: 1.5, from: &t)
        feed(&detector, 0.7, for: 0.2, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }

    @Test("a click is not speech")
    func ignoresAClick() {
        var detector = SilenceDetector()
        var t = 0.0
        feed(&detector, 0.9, for: 0.1, from: &t)
        feed(&detector, 0.02, for: 5, from: &t)
        #expect(detector.quiet(at: start.addingTimeInterval(t)) == nil)
    }
}
