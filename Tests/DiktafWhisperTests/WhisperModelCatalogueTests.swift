import DiktafCore
import Foundation
import Testing
@testable import DiktafWhisper

/// The catalogue, tested where it can be: what a variant is called, where its
/// weights land, and whether they are there.
///
/// Transcribing is not tested. It needs a microphone, a desktop session and six
/// hundred megabytes of weights, and a test that quietly downloads those is a
/// test nobody can run. What *is* worth pinning is the pair of facts that decide
/// whether the download button ever appears: the path WhisperKit puts weights at,
/// which is reproduced here rather than remembered, and what counts as installed.
@Suite("Whisper model catalogue")
struct WhisperModelCatalogueTests {

    // MARK: - Naming

    @Test("nil means the recommended model rather than nothing")
    func nilIsRecommended() {
        #expect(WhisperModelCatalogue.model(named: nil) == WhisperModelCatalogue.recommended)
        #expect(WhisperModelCatalogue.model(named: "") == WhisperModelCatalogue.recommended)
    }

    /// The model the whole feature was added for. If this stops being the
    /// recommendation it should be because somebody decided that, not because a
    /// list got reordered.
    @Test("the recommended model is large-v3-turbo")
    func recommendedIsTurbo() {
        #expect(WhisperModelCatalogue.recommended.variant
            == "openai_whisper-large-v3-v20240930_turbo_632MB")
    }

    @Test("every offered model is named once and describes itself")
    func choicesAreWellFormed() {
        let variants = WhisperModelCatalogue.choices.map(\.variant)
        #expect(Set(variants).count == variants.count)
        for model in WhisperModelCatalogue.choices {
            #expect(!model.label.isEmpty)
            #expect(!model.detail.isEmpty)
            #expect(model.megabytes > 0, "\(model.variant) claims no size")
        }
    }

    /// A variant somebody put in the settings file by hand is kept, because the
    /// repository has twenty-nine of these and this list offers three. Replacing
    /// it with the recommended one would silently undo a deliberate choice.
    @Test("a variant this list does not know is kept rather than replaced")
    func unknownVariantSurvives() {
        let model = WhisperModelCatalogue.model(named: "openai_whisper-medium")
        #expect(model.variant == "openai_whisper-medium")
        #expect(model != WhisperModelCatalogue.recommended)
        #expect(model.megabytes == 0, "an unknown model cannot know its own size")
    }

    // MARK: - Where the weights go

    /// The layout is WhisperKit's, not ours: `downloadBase/models/<repo>/<variant>`.
    /// We reproduce it so that a cold launch can answer "is it already there"
    /// without having downloaded anything, which means this test is the only thing
    /// standing between a working button and one that offers to re-download a
    /// model that is sitting on disk.
    @Test("the folder matches the layout WhisperKit downloads into")
    func folderMatchesWhisperKitLayout() {
        let base = URL(fileURLWithPath: "/tmp/diktaf-test-base")
        let catalogue = WhisperModelCatalogue(downloadBase: base)
        let folder = catalogue.folder(for: WhisperModelCatalogue.recommended)

        #expect(folder.filePath == "/tmp/diktaf-test-base/models/argmaxinc/whisperkit-coreml/"
                + "openai_whisper-large-v3-v20240930_turbo_632MB")
    }

    @Test("the default download base is somewhere the system will not empty")
    func defaultBaseIsNotCaches() {
        let path = WhisperModelCatalogue.defaultDownloadBase.filePath
        #expect(path.contains("Application Support"))
        #expect(!path.contains("/Caches/"))
    }

    /// The bug this exists for, and it would have broken the feature outright on
    /// every Mac. `URL.path()` percent-encodes, the weights live under
    /// "Application Support", and `Application%20Support` is a path that matches
    /// nothing: a model would download perfectly and then report itself as not
    /// installed forever. The space is the whole test.
    @Test("a path with a space in it is not percent-encoded")
    func pathsAreNotPercentEncoded() throws {
        let base = URL(fileURLWithPath: "/tmp/diktaf test base")
        let catalogue = WhisperModelCatalogue(downloadBase: base)
        let model = WhisperModelCatalogue.recommended
        let folder = catalogue.folder(for: model)

        #expect(!folder.filePath.contains("%20"))
        #expect(folder.filePath.contains("diktaf test base"))

        defer { try? FileManager.default.removeItem(at: base) }
        try place(Self.networks, extensionName: "mlmodelc", in: folder)
        try catalogue.markInstalled(model)
        #expect(catalogue.state(of: model) == .installed,
                "a folder with a space in its path was not found")
    }

    // MARK: - Installed or not

    @Test("nothing on disk means nothing installed")
    func emptyDiskIsNotInstalled() throws {
        try withTemporaryBase { catalogue, _ in
            #expect(catalogue.state(of: WhisperModelCatalogue.recommended) == .notInstalled)
        }
    }

    @Test("all three networks present and marked means installed",
          arguments: ["mlmodelc", "mlpackage"])
    func completeDownloadIsInstalled(_ extensionName: String) throws {
        try withTemporaryBase { catalogue, model in
            try place(Self.networks, extensionName: extensionName, in: catalogue.folder(for: model))
            try catalogue.markInstalled(model)
            #expect(catalogue.state(of: model) == .installed)
        }
    }

    /// The reason the check is for the three networks rather than for the folder.
    /// An interrupted download leaves the directory there with some of its
    /// contents, and a catalogue that called that installed would report ready and
    /// fail at the first dictation instead.
    @Test("an interrupted download is not installed")
    func partialDownloadIsNotInstalled() throws {
        try withTemporaryBase { catalogue, model in
            try place(["MelSpectrogram", "AudioEncoder"],
                      extensionName: "mlmodelc",
                      in: catalogue.folder(for: model))
            #expect(catalogue.state(of: model) == .notInstalled)
        }
    }

    /// The case the marker exists for. Each `.mlmodelc` folder appears with its
    /// first small file, long before its weights arrive, so a download cut off
    /// halfway has all three networks and none of what makes them run.
    @Test("three networks whose weights never arrived are not installed")
    func networksWithoutWeightsAreNotInstalled() throws {
        try withTemporaryBase { catalogue, model in
            let folder = catalogue.folder(for: model)
            for name in Self.networks {
                let network = folder.appending(path: "\(name).mlmodelc")
                try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: network.appending(path: "metadata.json"))
            }
            #expect(catalogue.state(of: model) == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: marker(in: folder).filePath))
        }
    }

    /// A model downloaded before the marker existed has none and must still count
    /// as installed, or every Mac that already fetched it is offered the download
    /// again. Marked on the way, so the weights are looked through only once.
    @Test("a model installed before the marker existed is still installed, and is marked")
    func earlierInstallIsMigrated() throws {
        try withTemporaryBase { catalogue, model in
            let folder = catalogue.folder(for: model)
            try placeWeights(Self.networks, in: folder)

            #expect(catalogue.state(of: model) == .installed)
            #expect(FileManager.default.fileExists(atPath: marker(in: folder).filePath))
            #expect(catalogue.state(of: model) == .installed)
        }
    }

    @Test("an earlier install missing one network's weights is not installed")
    func earlierInstallMissingWeightsIsNotInstalled() throws {
        try withTemporaryBase { catalogue, model in
            let folder = catalogue.folder(for: model)
            try placeWeights(Self.networks, in: folder)
            try FileManager.default.removeItem(
                at: folder.appending(path: "TextDecoder.mlmodelc/weights/weight.bin"))

            #expect(catalogue.state(of: model) == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: marker(in: folder).filePath))
        }
    }

    @Test("an empty weights file is not a finished one")
    func emptyWeightsAreNotInstalled() throws {
        try withTemporaryBase { catalogue, model in
            let folder = catalogue.folder(for: model)
            try placeWeights(Self.networks, in: folder)
            try Data().write(to: folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"))

            #expect(catalogue.state(of: model) == .notInstalled)
        }
    }

    // MARK: - Reclaiming

    @Test("removing a model takes the weights and reports the space back")
    func removingReclaimsSpace() throws {
        try withTemporaryBase { catalogue, model in
            let folder = catalogue.folder(for: model)
            try place(Self.networks, extensionName: "mlmodelc", in: folder)
            try catalogue.markInstalled(model)
            #expect(catalogue.state(of: model) == .installed)

            let reclaimed = try catalogue.remove(model)
            #expect(reclaimed > 0, "three networks were removed and none took any space")
            #expect(catalogue.state(of: model) == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: folder.filePath))
        }
    }

    @Test("removing a model that is not there is not a failure")
    func removingNothingIsFine() throws {
        try withTemporaryBase { catalogue, model in
            let reclaimed = try catalogue.remove(model)
            #expect(reclaimed == 0)
            #expect(catalogue.state(of: model) == .notInstalled)
        }
    }

    // MARK: - Helpers

    private static let networks = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private func marker(in folder: URL) -> URL {
        folder.appending(path: WhisperModelCatalogue.installedMarker)
    }

    /// A catalogue pointed at a directory of its own, cleaned up afterwards.
    private func withTemporaryBase(
        _ body: (WhisperModelCatalogue, WhisperModel) throws -> Void
    ) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "diktaf-whisper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try body(WhisperModelCatalogue(downloadBase: base),
                 WhisperModelCatalogue.recommended)
    }

    /// Stand-ins for the compiled networks: a directory per name, with a byte in
    /// it so that the size on disk is something rather than zero.
    private func place(
        _ names: [String],
        extensionName: String,
        in folder: URL
    ) throws {
        for name in names {
            let network = folder.appending(path: "\(name).\(extensionName)")
            try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: network.appending(path: "model.bin"))
        }
    }

    /// Compiled networks laid out the way Argmax's repository ships them, with
    /// the files a finished download has, and no marker.
    private func placeWeights(_ names: [String], in folder: URL) throws {
        for name in names {
            let network = folder.appending(path: "\(name).mlmodelc")
            try FileManager.default.createDirectory(
                at: network.appending(path: "weights"), withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: network.appending(path: "coremldata.bin"))
            try Data("weights".utf8).write(to: network.appending(path: "weights/weight.bin"))
        }
    }
}
