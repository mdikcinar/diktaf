import AVFoundation
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

/// Reserving a language, which is what turns a download into a usable language.
///
/// Downloading the assets is not enough on its own. Fetched without the locale
/// being reserved, the download completes and the language stays unusable:
/// `installedLocales` does not list it, the status stays `.supported`, and
/// `bestAvailableAudioFormat` returns nil — so a dictation in it cannot start.
/// Reserving it then fixed all three without fetching anything again, which is
/// why `install` reserves first.
///
/// What these can check is the reservation itself. The download cannot be tested
/// here: it is hundreds of megabytes and it changes the machine.
@Suite("Reserving a language")
struct LocaleReservationTests {
    private let catalogue = SpeechModelCatalogue()

    /// Reserving one that is already installed, so the test claims nothing the
    /// machine was not already using.
    @Test("reserving a language that is installed succeeds and is remembered")
    func reservesAnInstalledLanguage() async {
        let installed = await catalogue.installedLocales()
        guard let first = installed.first else { return }

        #expect(await catalogue.reserve(first))
        let reserved = await catalogue.reservedLocales().map { $0.identifier(.bcp47) }
        #expect(reserved.contains(first.identifier(.bcp47)))
    }

    /// Why the test above failed on every run but the first: `AssetInventory
    /// .reserve` answers `false` for a language already reserved, so one held
    /// since the last launch looked as if it could not be kept.
    @Test("reserving a language that is already reserved still reports it reserved")
    func reservingTwiceIsStillReserved() async {
        let installed = await catalogue.installedLocales()
        guard let first = installed.first else { return }

        await catalogue.reserve(first)
        #expect(await catalogue.reserve(first))
    }

    @Test("there is a limit, and it is the system's")
    func hasALimit() async {
        #expect(SpeechModelCatalogue.maximumReservedLocales > 0)
        #expect(await catalogue.reservedLocales().count
                <= SpeechModelCatalogue.maximumReservedLocales)
    }

    /// Reserving one that cannot be transcribed is not something to attempt.
    @Test("an unsupported language is not reserved")
    func refusesUnsupportedLanguages() async {
        #expect(await catalogue.reserve(Locale(identifier: "zz-ZZ")) == false)
    }
}

/// The level the indicator draws, measured in the tap on the audio thread.
@Suite("Input level")
struct InputMeterTests {
    @Test("the meter maps -50 dBFS to empty and -10 dBFS to full")
    func meterRange() {
        #expect(InputMeter.level(ofRMS: 0) == 0)
        #expect(abs(InputMeter.level(ofRMS: rms(decibels: -50))) < 0.001)
        #expect(abs(InputMeter.level(ofRMS: rms(decibels: -30)) - 0.5) < 0.001)
        #expect(abs(InputMeter.level(ofRMS: rms(decibels: -10)) - 1) < 0.001)
        #expect(InputMeter.level(ofRMS: 1) == 1)
    }

    @Test("a loud buffer fills the meter, silence lets it fall, and time is counted")
    func measuresBuffers() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let meter = InputMeter(sampleRate: 48_000)

        meter.measure(try buffer(of: 0.5, frames: 4_800, format: format))
        #expect(meter.level == 1)

        meter.measure(try buffer(of: 0, frames: 4_800, format: format))
        #expect(meter.level < 1)
        #expect(meter.level > 0)
        #expect(abs(meter.seconds - 0.2) < 0.000_1)
    }

    private func buffer(of value: Float, frames: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<frames { channel[index] = value }
        return buffer
    }

    private func rms(decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }
}
