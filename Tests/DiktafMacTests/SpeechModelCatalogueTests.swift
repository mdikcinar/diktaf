import DiktafCore
import Foundation
import Testing
@testable import DiktafMac

/// What the Speech framework means, as against what it looks like it means.
///
/// These are not tests of Diktaf's logic so much as of two assumptions that were
/// wrong the first time and cost the whole application: one silently made
/// dictation impossible on a machine that was ready, and the other made a
/// language look supported that is not. Both are cheap to pin and expensive to
/// rediscover.
@Suite("Speech model catalogue")
struct SpeechModelCatalogueTests {
    private let catalogue = SpeechModelCatalogue()

    /// The bug this exists for: `AssetInventory.status(forModules:)` answers
    /// `.supported` for a locale whose model is already installed and reserved.
    /// Believing it meant reporting `.notInstalled` for every language on the
    /// machine, and `SystemTranscriber` refusing to start a single dictation.
    @Test("every installed language reports that it is installed")
    func installedLanguagesAreUsable() async {
        let installed = await catalogue.installedLocales()
        try? #require(!installed.isEmpty, "this Mac has no speech model at all")

        for locale in installed {
            #expect(await catalogue.state(of: locale) == .installed,
                    "\(locale.identifier(.bcp47)) is installed but did not say so")
        }
    }

    /// The other one: `supportedLocale(equivalentTo:)` normalises an identifier
    /// without saying whether it is supported. Handed a language the framework
    /// cannot transcribe it hands back a tidy identifier, and taking that as a
    /// yes means failing later, further from the cause.
    @Test("a language the recogniser does not have is refused here, not later",
          arguments: ["zz-ZZ", "xx", "klingon"])
    func refusesUnsupportedLanguages(_ identifier: String) async {
        #expect(await catalogue.resolve(Locale(identifier: identifier)) == nil)
        #expect(await catalogue.state(of: Locale(identifier: identifier)) == .unsupported)
    }

    /// The reason `DictationTranscriber` is the module rather than
    /// `SpeechTranscriber`: the latter has no Turkish, and neither do the Nordic
    /// languages, Russian, Polish, Arabic or Hindi. For a dictation application
    /// that is the difference between usable and not.
    @Test("the languages the other recogniser lacks are supported", arguments: [
        "tr-TR", "ru-RU", "pl-PL", "ar-SA", "hi-IN", "nl-NL", "sv-SE",
    ])
    func supportsWhatDictationNeeds(_ identifier: String) async {
        let resolved = await catalogue.resolve(Locale(identifier: identifier))

        #expect(resolved != nil, "\(identifier) should be transcribable")
        #expect(resolved?.language.languageCode
                == Locale(identifier: identifier).language.languageCode)
    }

    @Test("an exact match is preferred over another region's model")
    func prefersTheExactLocale() async {
        let resolved = await catalogue.resolve(Locale(identifier: "en-GB"))

        #expect(resolved?.identifier(.bcp47) == "en-GB")
    }

    /// "en" rather than "en-US": a language with no region still has to work,
    /// because that is what a settings file written by hand looks like.
    @Test("a bare language code finds a model")
    func resolvesBareLanguageCodes() async {
        let resolved = await catalogue.resolve(Locale(identifier: "de"))

        #expect(resolved?.language.languageCode?.identifier == "de")
    }

    /// A Mac set to English in Turkey is `en_TR`, which no recogniser has a model
    /// for. Falling back to an English that is already installed is the
    /// difference between dictating now and being told to download a second
    /// English first.
    @Test("a region with no model of its own falls back to an installed variant")
    func prefersAnInstalledVariant() async {
        let installed = await catalogue.installedLocales()
        let english = installed.filter { $0.language.languageCode?.identifier == "en" }
        try? #require(!english.isEmpty, "this Mac has no English model")

        let resolved = await catalogue.resolve(Locale(identifier: "en_TR"))

        #expect(resolved != nil)
        #expect(english.contains { $0.identifier(.bcp47) == resolved?.identifier(.bcp47) },
                "resolved to \(resolved?.identifier(.bcp47) ?? "nil"), which is not installed")
        #expect(await catalogue.state(of: Locale(identifier: "en_TR")) == .installed)
    }

    @Test("the supported list is the framework's, not a copy of it")
    func readsTheFrameworkList() async {
        let supported = await catalogue.supportedLocales()

        #expect(supported.count > 40, "expected the dictation model's full list")
        let installed = await catalogue.installedLocales()
        #expect(installed.allSatisfy { candidate in
            supported.contains { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }
        }, "a model is installed for a language that is not on the supported list")
    }
}
