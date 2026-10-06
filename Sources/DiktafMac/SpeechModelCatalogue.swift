import DiktafCore
import Foundation
import Speech

/// The on-device speech models: which languages there are, and installing one.
///
/// Its own type rather than part of `SystemTranscriber` because installing a
/// model is not transcribing. It takes minutes, it has progress worth showing,
/// and it is the settings window's business — while the `Transcriber` port is
/// about one dictation and must not grow a download into it.
///
/// ## Why `DictationTranscriber` and not `SpeechTranscriber`
///
/// The Speech framework offers two recognisers and they do not cover the same
/// languages. `SpeechTranscriber`, the one aimed at transcribing recordings,
/// supports 30 locales — German, English, Spanish, French, Italian, Japanese,
/// Korean, Portuguese, Chinese, and nothing else. `DictationTranscriber`, which
/// is the model behind the system's own dictation, supports 54, and among them
/// are Turkish, Russian, Polish, Arabic, Hindi and the Nordic languages.
///
/// For an application whose whole purpose is dictation, the dictation model is
/// both the better fit and the difference between working in Turkish and not.
public struct SpeechModelCatalogue: Sendable {
    public init() {}

    /// The preset that reports the tail it is still revising, which is what lets
    /// the indicator show words as they are said. Long-form because a dictation
    /// is a paragraph, not a phrase.
    static let preset = DictationTranscriber.Preset.progressiveLongDictation

    static func module(for locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: preset)
    }

    /// Every language the recogniser supports here, installed or not.
    public func supportedLocales() async -> [Locale] {
        await DictationTranscriber.supportedLocales
    }

    /// The ones whose model is on disk and usable right now.
    public func installedLocales() async -> [Locale] {
        await DictationTranscriber.installedLocales
    }

    /// The locale the recogniser would actually use for this one, or nil if it
    /// cannot transcribe this language at all.
    ///
    /// Checked against `supportedLocales` rather than by asking
    /// `supportedLocale(equivalentTo:)`, which normalises an identifier without
    /// telling you whether it is supported: handed Turkish it answers "tr-TR"
    /// whether or not Turkish is on the list. Taking it at its word means
    /// failing later, further from the cause.
    public func resolve(_ locale: Locale) async -> Locale? {
        let supported = await supportedLocales()
        let wanted = locale.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted }) {
            return exact
        }

        let sameLanguage = supported.filter {
            $0.language.languageCode == locale.language.languageCode
        }
        guard !sameLanguage.isEmpty else { return nil }

        // A region with no model of its own — a Mac set to English in Turkey is
        // `en_TR` — falls back to another variant of the same language. An
        // installed one for preference: any of them will transcribe, and picking
        // one already on disk is the difference between dictating now and being
        // asked to download a second English.
        let installed = await installedLocales().map { $0.identifier(.bcp47) }
        return sameLanguage.first { installed.contains($0.identifier(.bcp47)) }
            ?? sameLanguage.first
    }

    /// Whether this language can be transcribed now, later, or not at all.
    ///
    /// `installedLocales` is the authority on "now", and it has to be:
    /// `AssetInventory.status(forModules:)` answers `.supported` for a locale
    /// whose model is already installed and in use. Believing that instead would
    /// mean refusing every dictation on a machine that was perfectly ready.
    public func state(of locale: Locale) async -> ModelState {
        guard let resolved = await resolve(locale) else { return .unsupported }
        let wanted = resolved.identifier(.bcp47)
        if await installedLocales().contains(where: { $0.identifier(.bcp47) == wanted }) {
            return .installed
        }
        return switch await AssetInventory.status(forModules: [Self.module(for: resolved)]) {
        case .installed: .installed
        case .downloading: .downloading
        case .unsupported: .unsupported
        case .supported: .notInstalled
        @unknown default: .notInstalled
        }
    }

    /// Downloads and installs the model for a language.
    ///
    /// `progress` is handed the system's own `Progress` as soon as there is one,
    /// so the settings window can show a bar rather than a spinner. Returns when
    /// the model is usable.
    public func install(
        _ locale: Locale,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        guard let resolved = await resolve(locale) else {
            throw TranscriptionFailure.languageUnavailable(locale.identifier)
        }

        // Reserved before it is fetched, and this order is not optional.
        //
        // Downloading the assets does not make a language usable on its own.
        // Fetched without reserving the locale, the download runs to completion
        // and the language stays unusable: `installedLocales` does not list it,
        // `status(forModules:)` still answers `.supported`, and
        // `bestAvailableAudioFormat` returns nil, so a dictation in it cannot
        // start. Reserving it afterwards fixed all three without fetching
        // anything again — but doing it first means an interrupted download
        // leaves a language that is merely incomplete, rather than one that is
        // complete and still refuses to work.
        await reserve(resolved)

        guard let request = try await AssetInventory
            .assetInstallationRequest(supporting: [Self.module(for: resolved)]) else {
            return                     // nothing to fetch
        }
        progress?(request.progress)
        try await request.downloadAndInstall()
    }

    /// How many languages may be held at once, which is a system limit rather
    /// than one of Diktaf's.
    public static var maximumReservedLocales: Int { AssetInventory.maximumReservedLocales }

    /// The languages this application has asked the system to keep.
    public func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    /// Asks the system to keep this language's model rather than reclaiming it,
    /// and answers whether it is reserved now.
    ///
    /// Worth doing for the language actually dictated in: an unreserved model can
    /// be removed to free space, and the next dictation would then fail with a
    /// download to do. Five may be held at once, so this reports rather than
    /// insists.
    ///
    /// The answer is checked against `reservedLocales` when the framework says
    /// no, because `AssetInventory.reserve` answers `false` for a language that
    /// is already reserved — which is the outcome asked for, not a refusal.
    @discardableResult
    public func reserve(_ locale: Locale) async -> Bool {
        guard let resolved = await resolve(locale) else { return false }
        if (try? await AssetInventory.reserve(locale: resolved)) == true { return true }
        let wanted = resolved.identifier(.bcp47)
        return await reservedLocales().contains { $0.identifier(.bcp47) == wanted }
    }

    public enum ModelState: Sendable, Equatable {
        case installed
        case notInstalled
        case downloading
        case unsupported
    }
}
