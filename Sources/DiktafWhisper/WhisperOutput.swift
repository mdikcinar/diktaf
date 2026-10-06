import Foundation
import WhisperKit

/// What Whisper said, minus what it makes up over silence: a sound in brackets,
/// one phrase on a loop. This WhisperKit's own guards do nothing — `noSpeechProb`
/// is always 0, and its thresholds act only through fallbacks, which are off.
enum WhisperOutput {
    /// Past this, a segment is mostly one phrase over and over. The figure
    /// Whisper's own decoder uses for the same judgement.
    static let maximumCompressionRatio: Float = 2.4

    /// The transcript of one pass, as one string.
    static func transcript(of results: [TranscriptionResult]) -> String {
        results
            .map { text(of: $0.segments.map(\.text)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// One result's segments, minus those that are not speech. Joined as written,
    /// since each carries its own leading space and a language without spaces must
    /// gain none; trimmed, so that space is not the first character pasted.
    static func text(of segments: [String]) -> String {
        segments
            .filter(isSpeech)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSpeech(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSoundTag(trimmed) else { return false }
        return TextUtilities.compressionRatio(of: trimmed) <= maximumCompressionRatio
    }

    /// Whether a segment only describes a sound — `*phone rings*`, `[Müzik]`,
    /// `(music)`, `♪ … ♪` — or is empty: with the tags out, no letter or digit
    /// is left.
    static func isSoundTag(_ segment: String) -> Bool {
        let tags = /\*[^*]*\*|\[[^\]]*\]|\([^)]*\)|（[^）]*）|【[^】]*】|♪[^♪]*♪|[♪♫♬🎵🎶]/
        return !segment
            .replacing(tags, with: "")
            .contains { $0.isLetter || $0.isNumber }
    }
}
