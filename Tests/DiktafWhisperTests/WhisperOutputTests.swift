import Foundation
import Testing
@testable import DiktafWhisper

/// What Whisper is shown, and what is kept of what it says. Every tag here was
/// seen in a real dictation over silence; the defences are a gate in front of
/// the model and a filter behind it.
@Suite("What Whisper hears and says")
struct WhisperOutputTests {

    // MARK: - Sound tags

    @Test("a segment that only describes a sound is dropped", arguments: [
        "*phone rings*", " *Gunshot* ", "[Müzik]", "(music)", "♪ la la la ♪",
        "[Music] [Applause]", "♪", "（拍手）", "【音楽】", "", "   ", "...",
    ])
    func soundTagsAreNotSpeech(_ segment: String) {
        #expect(WhisperOutput.isSoundTag(segment))
        #expect(!WhisperOutput.isSpeech(segment))
    }

    /// The filter is for what is *only* a tag. Words Whisper also likes to make
    /// up over silence are still words when somebody says them, and keeping
    /// them out is the gate's job, not this one's.
    @Test("real words are kept, including ones Whisper invents over silence", arguments: [
        "Hello world.", "Müzik", "¡Gracias!", "はい", "Firebase CLI'ı kur.",
        "I said (quietly) that it works.", "Version 2",
    ])
    func wordsAreSpeech(_ segment: String) {
        #expect(!WhisperOutput.isSoundTag(segment))
        #expect(WhisperOutput.isSpeech(segment))
    }

    // MARK: - Repetition

    @Test("a phrase repeated until the window ran out is dropped")
    func repetitionLoopsAreNotSpeech() {
        let loop = String(repeating: " Thank you.", count: 30)
        #expect(!WhisperOutput.isSpeech(loop))
    }

    @Test("an ordinary long sentence is not mistaken for a loop")
    func ordinaryProseIsSpeech() {
        let prose = """
        Firebase CLI'ı kurduktan sonra projeyi seçip deploy komutunu çalıştırdım, \
        ama hosting ayarlarında yönlendirme kuralı eksik olduğu için ana sayfa \
        açılmadı; yarın sabah ilk iş olarak yapılandırma dosyasını düzelteceğim.
        """
        #expect(WhisperOutput.isSpeech(prose))
    }

    // MARK: - Joining

    @Test("segments are joined as written, with the tags taken out")
    func tagsAreRemovedFromTheJoin() {
        #expect(WhisperOutput.text(of: [" Hello", " *cough*", " world."]) == "Hello world.")
    }

    /// Japanese has no spaces between words, and Whisper's segments for it
    /// carry none, so joining with a space would put one in.
    @Test("a language written without spaces gains none")
    func noSpacesAreAdded() {
        #expect(WhisperOutput.text(of: ["はい", "そうです"]) == "はいそうです")
    }

    @Test("a pass that heard only sounds is empty")
    func onlyTagsIsEmpty() {
        #expect(WhisperOutput.text(of: [" [Müzik]", " *phone rings*"]) == "")
    }

    // MARK: - The gate

    @Test("silence is not shown to the model")
    func silenceIsNotSpeech() {
        #expect(!WhisperTranscriber.containsSpeech(Array(repeating: 0, count: 3 * 16_000)))
        #expect(!WhisperTranscriber.containsSpeech([]))
    }

    @Test("the hum of a quiet room is not shown to the model")
    func roomNoiseIsNotSpeech() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(3 * 16_000)).map { _ in Float.random(in: -0.003...0.003, using: &generator) }
        #expect(!WhisperTranscriber.containsSpeech(noise))
    }

    /// One loud tenth of a second — a key, a tap on the desk — is not a word.
    @Test("a single click in the silence is not shown to the model")
    func aClickIsNotSpeech() {
        var samples = [Float](repeating: 0, count: 3 * 16_000)
        for index in 16_000..<17_600 { samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        #expect(!WhisperTranscriber.containsSpeech(samples))
    }

    @Test("a voice is shown to the model, even a quiet one", arguments: [Float(0.1), 0.02])
    func voiceIsSpeech(_ amplitude: Float) {
        var samples = [Float](repeating: 0, count: 3 * 16_000)
        for index in 16_000..<32_000 {
            samples[index] = amplitude * sin(2 * .pi * 220 * Float(index) / 16_000)
        }
        #expect(WhisperTranscriber.containsSpeech(samples))
    }

    // MARK: - The level meter

    @Test("the meter maps -50 dBFS to empty and -10 dBFS to full")
    func meterRange() {
        #expect(LiveRecording.level(ofRMS: 0) == 0)
        #expect(LiveRecording.level(ofRMS: 0.000_001) == 0)
        #expect(abs(LiveRecording.level(ofRMS: rms(decibels: -50))) < 0.001)
        #expect(abs(LiveRecording.level(ofRMS: rms(decibels: -30)) - 0.5) < 0.001)
        #expect(abs(LiveRecording.level(ofRMS: rms(decibels: -10)) - 1) < 0.001)
        #expect(LiveRecording.level(ofRMS: 1) == 1)
    }

    @Test("the meter rises at once and falls back gradually")
    func meterDecays() {
        let live = LiveRecording(window: 16_000)
        live.append([Float](repeating: 0.5, count: 1_600))
        let loud = live.level
        #expect(loud == 1)

        live.append([Float](repeating: 0, count: 1_600))
        #expect(live.level < loud)
        #expect(live.level > 0)
    }

    @Test("the live copy keeps the preview window and counts everything")
    func liveCopyIsBounded() {
        let live = LiveRecording(window: 1_000)
        for value in 0..<50 {
            live.append([Float](repeating: Float(value), count: 100))
        }
        #expect(live.sampleCount == 5_000)
        #expect(live.recentSamples.count == 1_000)
        #expect(live.recentSamples.last == 49)
        #expect(live.recentSamples.first == 40)
    }

    private func rms(decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }
}
