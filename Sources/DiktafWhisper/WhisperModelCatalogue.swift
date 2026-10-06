import DiktafCore
import Foundation
import WhisperKit

/// One set of Whisper weights the user can choose, as something nameable.
///
/// The `variant` is a directory name in the model repository and is the only part
/// the machine cares about; everything else exists so that a person choosing
/// between them is choosing between described things rather than between strings
/// like `openai_whisper-large-v3-v20240930_turbo_632MB`.
public struct WhisperModel: Sendable, Identifiable, Hashable {
    /// The directory name in `WhisperModelCatalogue.repository`.
    public let variant: String

    /// What the picker calls it.
    public let label: String

    /// The trade-off it represents, in one sentence.
    public let detail: String

    /// What the download costs, in whole megabytes. Measured from the repository
    /// rather than guessed, because this number is the entire reason somebody
    /// picks one of these over another.
    public let megabytes: Int

    public var id: String { variant }

    public init(variant: String, label: String, detail: String, megabytes: Int) {
        self.variant = variant
        self.label = label
        self.detail = detail
        self.megabytes = megabytes
    }
}

/// Which Whisper models there are, whether their weights are here, and fetching
/// them.
///
/// The counterpart of `SpeechModelCatalogue` for the other engine, and
/// deliberately the same shape: a list to choose from, a state per item, and an
/// `install` that reports progress. The settings window should not have to know
/// which engine it is talking about to draw a download button.
///
/// The difference is what a model covers. Apple's recogniser has one model per
/// language and the choice is *which language*; Whisper has one model for all 99
/// of them and the choice is *how big*. So there is nothing here about locales:
/// a downloaded Whisper transcribes Turkish and English out of the same weights.
public struct WhisperModelCatalogue: Sendable {
    /// Where the weights come from. Argmax's own conversions, which are what
    /// WhisperKit expects and the only ones it can load without a custom repo.
    public static let repository = "argmaxinc/whisperkit-coreml"

    /// The models offered, largest first is *not* the order: the recommended one
    /// leads, because a list sorted by size invites picking on size alone.
    ///
    /// Three rather than the repository's twenty-nine. The rest are either worse
    /// at the same size, English-only — which for a Turkish dictation is not a
    /// trade-off but a failure — or old enough that a newer one beats them
    /// outright.
    public static let choices: [WhisperModel] = [
        WhisperModel(
            variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
            label: "Whisper large-v3-turbo",
            detail: """
            Önerilen model. Neural Engine için sıkıştırılmış; Türkçe bir \
            cümledeki teknik kelimeleri duyan da bu.
            """,
            megabytes: 646),
        WhisperModel(
            variant: "openai_whisper-large-v3-v20240930_turbo",
            label: "Whisper large-v3-turbo, tam hassasiyet",
            detail: """
            Aynı model, sıkıştırmasız. Biraz daha isabetli; indirmesi iki buçuk \
            kat büyük, yüklenmesi daha yavaş.
            """,
            megabytes: 1639),
        WhisperModel(
            variant: "openai_whisper-small_216MB",
            label: "Whisper small",
            detail: """
            Yeri ya da belleği kısıtlı bir Mac için. Her konuda large-v3-turbo'dan \
            belirgin biçimde zayıf, asıl aradığınız kelimelerde de.
            """,
            megabytes: 217),
    ]

    /// What `nil` in the settings means.
    public static var recommended: WhisperModel { choices[0] }

    /// The model a stored variant name refers to.
    ///
    /// A name that is not on the list is kept as a model of its own rather than
    /// replaced by the recommended one — somebody who put a variant in the
    /// settings file by hand meant it, and the repository has plenty this list
    /// leaves out. Its size is unknown, which is what `0` says here.
    public static func model(named variant: String?) -> WhisperModel {
        guard let variant, !variant.isEmpty else { return recommended }
        return choices.first { $0.variant == variant }
            ?? WhisperModel(variant: variant,
                            label: variant,
                            detail: "Elle ayarlanmış; burada sunulan modellerden biri değil.",
                            megabytes: 0)
    }

    /// The directory the weights and the tokeniser live under.
    ///
    /// Application Support rather than Caches, and the distinction is not
    /// pedantic: this is hundreds of megabytes the user chose to fetch and waited
    /// for, and the system empties Caches whenever it likes. A dictation engine
    /// that silently uninstalls itself when the disk fills up is worse than one
    /// that was never installed.
    public let downloadBase: URL

    public init(downloadBase: URL? = nil) {
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase
    }

    static var defaultDownloadBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        return support.appending(path: "Diktaf/WhisperModels")
    }

    /// Where `WhisperKit.download` puts this variant.
    ///
    /// Reproduced here rather than remembered from a download, because the
    /// question "is it already there" is asked on a cold launch when no download
    /// has happened. It has to match what WhisperKit does — `downloadBase` then
    /// `models`, then the repository, then the variant — and if that ever
    /// changes, this is the line that says so.
    public func folder(for model: WhisperModel) -> URL {
        downloadBase
            .appending(path: "models")
            .appending(path: Self.repository)
            .appending(path: model.variant)
    }

    /// Whether this model can be dictated with right now.
    ///
    /// The three compiled networks have to be there, under either extension Core
    /// ML uses, and so does the marker `install` leaves once the model is fetched
    /// *and* prepared. The networks alone prove nothing: each `.mlmodelc` folder
    /// appears with its first small file, long before its weights do.
    ///
    /// A model installed before the marker existed counts if all its weights are
    /// there, and is marked, rather than being offered for download again.
    public func state(of model: WhisperModel) -> ModelState {
        let folder = folder(for: model)
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.filePath) else { return .notInstalled }

        let networksPresent = Self.requiredNetworks.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { extensionName in
                manager.fileExists(
                    atPath: folder.appending(path: "\(name).\(extensionName)").filePath)
            }
        }
        guard networksPresent else { return .notInstalled }

        if manager.fileExists(atPath: folder.appending(path: Self.installedMarker).filePath) {
            return .installed
        }
        guard Self.weightsAreComplete(in: folder) else { return .notInstalled }
        try? markInstalled(model)
        return .installed
    }

    static let requiredNetworks = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// Written by `install` as its last step, so that its presence means every
    /// part of the install finished. Inside the model's folder, so `remove`
    /// takes it with the weights.
    static let installedMarker = ".diktaf-installed"

    /// The files every compiled network in Argmax's repository has. The
    /// downloader writes each one elsewhere and moves it into place when it is
    /// complete, so a file here that is not empty is a file that finished.
    static let networkFiles = ["coremldata.bin", "weights/weight.bin"]

    /// Whether a model installed without the marker has all of its weights.
    static func weightsAreComplete(in folder: URL) -> Bool {
        let manager = FileManager.default
        return requiredNetworks.allSatisfy { name in
            networkFiles.allSatisfy { file in
                let path = folder.appending(path: "\(name).mlmodelc").appending(path: file).filePath
                let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                return size > 0
            }
        }
    }

    func markInstalled(_ model: WhisperModel) throws {
        try Data(model.variant.utf8)
            .write(to: folder(for: model).appending(path: Self.installedMarker))
    }

    /// How far along getting a model ready is.
    ///
    /// Two phases and not one, because they fail and feel different. The fetch
    /// has a byte count and a bar; the preparation has neither — Core ML is
    /// compiling the network for this particular chip — and a bar sitting at 100%
    /// through it reads as a hang.
    public enum InstallationPhase: Sendable {
        case downloading(Progress)
        case preparing
    }

    /// Fetches a model's weights and gets it to the point where a dictation can
    /// start without touching the network.
    ///
    /// The second half is what makes this more than a download. WhisperKit also
    /// needs a tokeniser, which it fetches separately the first time it loads a
    /// model, and Core ML has to specialise the network for this chip before it
    /// will run. Left to the first dictation, both of those happen while somebody
    /// is holding a hotkey down and waiting — and the tokeniser one fails outright
    /// on a Mac that has since gone offline. So the model is loaded once, here,
    /// where there is a progress indicator and nobody is mid-sentence, and then
    /// thrown away. Only after that is the model marked installed, which is
    /// what `state(of:)` looks for.
    public func install(
        _ model: WhisperModel,
        phase: (@Sendable (InstallationPhase) -> Void)? = nil
    ) async throws {
        let fetched: URL
        do {
            fetched = try await WhisperKit.download(
                variant: model.variant,
                downloadBase: downloadBase,
                from: Self.repository,
                progressCallback: { progress in phase?(.downloading(progress)) })
        } catch {
            throw TranscriptionFailure.underlying(
                "\(model.label) indirilemedi: \(error)")
        }

        phase?(.preparing)
        do {
            // `prewarm` loads the three networks one at a time and unloads each
            // before the next, so getting ready costs one network's worth of
            // memory rather than all three plus whatever compiling takes.
            //
            // The folder is passed rather than the variant name: with
            // `download: false` and no folder, WhisperKit never works out where
            // the weights are and fails having looked nowhere. The one the
            // download just returned is the authority on that.
            _ = try await WhisperKit(WhisperKitConfig(
                model: model.variant,
                downloadBase: downloadBase,
                modelRepo: Self.repository,
                modelFolder: fetched.filePath,
                tokenizerFolder: downloadBase,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false))
        } catch {
            throw TranscriptionFailure.underlying(
                "\(model.label) indirildi ama hazırlanamadı: \(error)")
        }

        do {
            try markInstalled(model)
        } catch {
            throw TranscriptionFailure.underlying(
                "\(model.label) hazırlandı ama kurulu olarak işaretlenemedi: \(error)")
        }
    }

    /// Deletes a model's weights, and reports how much came back.
    ///
    /// Here because these are the largest files the application will ever put on
    /// somebody's disk, and an engine you can switch away from but not reclaim the
    /// space from is a poor bargain.
    @discardableResult
    public func remove(_ model: WhisperModel) throws -> Int64 {
        let folder = folder(for: model)
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.filePath) else { return 0 }
        let reclaimed = Self.sizeOnDisk(of: folder)
        try manager.removeItem(at: folder)
        return reclaimed
    }

    static func sizeOnDisk(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: keys)
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    /// Deliberately the same cases as `SpeechModelCatalogue.ModelState`, minus
    /// the two that cannot happen here: Whisper has no background installation
    /// the system does on its own, and no language it refuses.
    public enum ModelState: Sendable, Equatable {
        case installed
        case notInstalled
    }
}

extension URL {
    /// The path as the file system means it, with nothing percent-encoded.
    ///
    /// `URL.path()` encodes by default, and the default is wrong for every use in
    /// this file. The weights live under `~/Library/Application Support`, which
    /// has a space in it, so `path()` hands back `Application%20Support` — a path
    /// no `FileManager` call and no Core ML load will ever match. The symptom is
    /// that a model downloads perfectly and then reports itself as not installed,
    /// forever, on every Mac.
    ///
    /// Named rather than written out at each call site, so that there is one
    /// place to be right and no new call site to get it wrong.
    var filePath: String { path(percentEncoded: false) }
}
