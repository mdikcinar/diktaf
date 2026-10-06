import DiktafCore
import Foundation
import Testing
@testable import DiktafWhisper

/// The one assumption in this adapter that cannot be checked without the network,
/// checked with the network.
///
/// `WhisperModelCatalogue.folder(for:)` reproduces the layout WhisperKit downloads
/// into, because a cold launch has to answer "are the weights already here"
/// without having downloaded anything. If that reproduction is wrong, everything
/// still compiles and every offline test still passes — and the feature is broken
/// in the one way that looks like nothing: the model downloads perfectly, the
/// catalogue reports it as missing, and the button offers to download it again,
/// forever.
///
/// So it is pinned against a real download of the smallest model in the
/// repository, and skipped unless asked for:
///
/// ```sh
/// DIKTAF_NETWORK_TESTS=1 swift test --filter WhisperDownloadTests
/// ```
///
/// Not part of `swift test` because it fetches tens of megabytes and needs a
/// network, and a suite that quietly does either is a suite people stop running.
@Suite("Whisper download", .enabled(if: ProcessInfo.processInfo
    .environment["DIKTAF_NETWORK_TESTS"] == "1"))
struct WhisperDownloadTests {

    /// `tiny` rather than the model anybody would use. This tests the path, not
    /// the transcription, and the path is the same for all of them.
    private static let tiny = WhisperModel(
        variant: "openai_whisper-tiny",
        label: "Whisper tiny",
        detail: "The smallest model in the repository, downloaded to check a path.",
        megabytes: 75)

    @Test("a real download lands exactly where the catalogue predicted")
    func downloadLandsWherePredicted() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "diktaf-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let catalogue = WhisperModelCatalogue(downloadBase: base)
        let model = Self.tiny

        #expect(catalogue.state(of: model) == .notInstalled)

        try await catalogue.install(model)

        // The whole point: the folder worked out from the download base alone
        // matches what WhisperKit actually did, and the completeness check agrees.
        #expect(catalogue.state(of: model) == .installed,
                "downloaded to \(catalogue.folder(for: model).filePath), and it was not found there")

        let reclaimed = try catalogue.remove(model)
        #expect(reclaimed > 1_000_000, "a model was removed and barely any space came back")
        #expect(catalogue.state(of: model) == .notInstalled)
    }
}
