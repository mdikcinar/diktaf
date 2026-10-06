# Architecture

Diktaf is a menu bar dictation app for macOS. Press a key, talk, press it
again: the recording is turned into text by a speech recogniser running on this
Mac, a local model cleans it up according to rules you wrote, and the
result lands in your clipboard and is pasted into whatever window you were
typing in. A second key sends what you said to the agent as a question instead.

No API keys and nothing over the network at dictation time. There are two
recognisers to choose between and both run here: Apple's own, which needs no
download, and Whisper large-v3-turbo as Core ML, whose weights are fetched once
from the settings window. Cleanup is a model Ollama serves on this Mac, or the
`claude` CLI you already have signed in; the agent is always Claude.

## The one rule

Dependencies point inwards, and `DiktafCore` imports Foundation and nothing
else. That single constraint is what makes a Windows build later a matter of
adding a target rather than starting over, and it is worth defending in review:
an `import AppKit` in Core is a bug however convenient it is.

```
        ┌──────────────────────────────────────────┐
        │  Diktaf          SwiftUI, MenuBarExtra   │  the app
        │                  composition root        │
        └───────────────┬──────────────────────────┘
                        │  picks an adapter per port
        ┌───────────────┴────┬───────────────┬─────┴────────┬──────────────┐
        │  DiktafMac         │ DiktafWhisper │ DiktafClaude │ DiktafOllama │  adapters
        │  Speech, AppKit    │ WhisperKit    │ Process      │ URLSession   │
        └───────────────┬────┴───────┬───────┴──────┬───────┴──────┬───────┘
                        │  conform to │              │              │
        ┌───────────────┴─────────────┴──────────────┴──────────────┴──────┐
        │  DiktafCore      domain + ports                                  │  Foundation only
        │  no platform, no processes, no UI                                │
        └──────────────────────────────────────────────────────────────────┘
```

Two adapters fill the same port, which is the arrangement the port was for.
`DiktafMac` and `DiktafWhisper` are both `Transcriber`s, neither knows the other
exists, and the object that picks between them —
`Diktaf/EngineSwitchingTranscriber` — is in the app because choosing is
composition.

`Sources/DiktafCore/Ports` holds the protocols. They are the contract between
the layers and are already written; implement against them rather than changing
them, and if one is genuinely wrong, say so rather than working around it.

* `Transcriber` — speech to text, as settled and volatile halves
* `TextRefiner` — raw transcript plus an instruction, cleaned text back
* `AgentRunner` — one turn of a conversation with a local agent
* `Clipboard`, `KeyboardSender`, `FocusGuard` — getting text into another window
* `HotkeyMonitor` — keys that arrive while another app has the keyboard
* `PermissionAuthority` — what the system has allowed
* `SettingsStorage` — bytes on disk

## Targets

| Target | Holds | May import |
| --- | --- | --- |
| `DiktafCore` | domain, ports, state machine, rules, prompt building | Foundation |
| `DiktafMac` | `SpeechAnalyzer`, `NSPasteboard`, `CGEvent`, hotkeys, permissions | Foundation, AppKit, Speech, AVFoundation, Carbon, DiktafCore |
| `DiktafWhisper` | Whisper as Core ML: the model catalogue and the download | Foundation, WhisperKit, DiktafCore |
| `DiktafClaude` | the `claude` CLI as a subprocess | Foundation, DiktafCore |
| `DiktafOllama` | cleanup through a local Ollama server, and its model list | Foundation, DiktafCore |
| `Diktaf` | SwiftUI, menu bar, settings, overlay, wiring | everything |

`DiktafWhisper` holds the package's only external dependency, and holds it alone
on purpose: a Mac whose owner never chooses Whisper pays nothing for it, and the
boundary is the one place to look when the dependency has to go.

## The domain

### Dictation, as a state machine

One session at a time, and every transition is one of these. Nothing else may
put the app into a state; the UI observes and the hotkeys ask.

```
  idle ──toggle──▶ recording ──toggle──▶ settling ──▶ refining ──▶ delivering ──▶ idle
   ▲                   │                    │            │             │
   └────── cancel ─────┴────────────────────┴────────────┴─────────────┘
```

* **recording** carries the live text so the indicator can show it, and the
  destination — the focused window, or the agent.
* **settling** is stopping the audio and waiting for the last words. It is a
  state of its own because it is not instant, and a user who has pressed stop
  needs to see that something is happening.
* **refining** is skipped when cleanup is off. If it fails, the *raw*
  transcript is delivered and the failure is reported — a dictation that
  arrives uncleaned beats one that disappears.
* **delivering** puts the text on the clipboard, restores the keyboard, and
  pastes or types it.
* **cancel** is reachable from everywhere and always ends at idle.

### Cleanup rules

Rules are the user's own sentences, each switchable, plus an optional free-form
instruction. The domain turns them into the prompt; the refiner never sees a
rule. Prompt building is ordinary testable code and must stay that way.

### Agent

A dictation whose destination is the agent becomes the prompt for one turn.
Replies are shown, not pasted, and the conversation can be continued — the
session identifier the runner hands back is kept until the user clears it.

### Two engines for cleanup

`DiktafOllama` and `DiktafClaude` both fill `TextRefiner`, and
`Diktaf/EngineSwitchingRefiner` picks between them at every cleanup — the same
arrangement as the two recognisers. Ollama is the default because it is an
order of magnitude faster once its model is in memory (about half a second
against several for `claude --model haiku`), so the app loads the model when a
dictation starts rather than when the cleanup does. An Ollama that is not
running or lacks the model hands the transcript to Claude within the same
deadline; any other Ollama failure is its own, and the raw transcript is
delivered as before.

### Showing the work

Besides its state, the session emits a `DictationProgress` at every step —
when recording began and ended, when the transcript was ready, which engine is
cleaning up and against which deadline, how it ended. The indicator is drawn
from that alone, plus two things the app asks the recogniser in use directly
and the port deliberately does not carry: the input level, and whether Whisper
is still loading. A progress event comes before the state change that follows
its step, and nothing is emitted for a dictation after it has been cancelled.

Cancelling is a generation counter in `DictationSession` and in each
recogniser: everything that awaits checks it afterwards, so work belonging to a
dictation that was thrown away can never deliver into the next one.

## Two things the Speech framework will mislead you about

Both were got wrong first time round, both are pinned by tests in
`DiktafMacTests`, and neither is guessable from the API.

**There are two recognisers and they do not cover the same languages.**
`SpeechTranscriber`, the one aimed at transcribing recordings, supports 30
locales: German, English, Spanish, French, Italian, Japanese, Korean,
Portuguese, Chinese. `DictationTranscriber`, the model behind the system's own
dictation, supports 54 — including Turkish, Russian, Polish, Arabic, Hindi and
the Nordic languages. Diktaf uses the second, which for a dictation application
is both the better fit and the difference between working in Turkish and not.

**`AssetInventory.status(forModules:)` does not tell you whether a model is
installed.** It answers `.supported` for a locale whose model is on disk and
reserved, and `assetInstallationRequest(supporting:)` hands back a request for it
anyway. `installedLocales` is the authority on what can be transcribed right now.
Believing the first one meant reporting every language as missing and refusing
every dictation on a machine that was perfectly ready.

**Downloading a model does not make its language usable.** Fetch the assets
without reserving the locale and the download runs to completion while the
language stays unusable: `installedLocales` does not list it, the status stays
`.supported`, and `bestAvailableAudioFormat` returns nil. `AssetInventory.reserve`
fixes all three without fetching anything again, so `install` reserves first, and
choosing a language in the settings reserves it too — reserving only after a
dictation has started, which is where this used to happen, is too late, because
the dictation is what cannot start.

A third, smaller trap: `supportedLocale(equivalentTo:)` normalises an identifier
without saying whether it is supported. Ask it about Turkish and it answers
`tr-TR` whether or not Turkish is on the list, so membership is checked against
`supportedLocales` instead.

And a fourth: `AssetInventory.reserve(locale:)` answers `false` for a locale
that is already reserved, which reads as a refusal. `SpeechModelCatalogue.reserve`
checks `reservedLocales` when it says no.

## The two recognisers

Neither wins outright, which is why it is a setting rather than a decision.

Apple's model is free, instant and already there, and it mishears any word its
language model does not expect — a Turkish sentence containing "Firebase CLI"
comes back with three Turkish words that sound like it. That is not a bug to fix
in the prompt: the information is gone before the cleanup agent sees it. Whisper
knows the vocabulary, and costs a download of a few hundred megabytes and a
couple of seconds to load after a restart.

**Whisper is not a streaming model, and the adapter is shaped by that.** Apple's
recogniser takes audio continuously and hands back a settled half and a volatile
half, which is exactly `TranscriptUpdate`. Whisper takes a *recording* — up to
thirty seconds of it — and returns the whole transcript at once. So the two
halves are earned differently in `WhisperTranscriber`:

* **volatile** is a preview. While recording, the audio so far is transcribed
  again from scratch every so often and each result replaces the last. It is what
  the indicator shows, it is thrown away, and it is allowed to be wrong.
* **settled** is produced exactly once, by `stop()`, from a single pass over the
  entire recording.

The final pass is not a compromise; it is the better design for this model.
Whisper reads a whole utterance and uses the end of a sentence to decide the
beginning of it, so one pass over everything beats any number of passes over
pieces.

Three things about the adapter are load-bearing and were each got wrong first:

**The microphone is owned separately from the pipeline.** Loading a Whisper model
takes seconds. A dictation that starts recording only once the model is ready
loses the opening of the sentence, which is the part that decides what the rest
of it means. So `WhisperTranscriber` owns a WhisperKit `AudioProcessor`, starts it
on the key press, and lets the model catch up.

**`URL.path()` percent-encodes, and the weights live under "Application
Support".** That space becomes `%20`, which matches no path on disk, and the
symptom is a model that downloads perfectly and then reports itself as not
installed forever, on every Mac. `URL.filePath` in `WhisperModelCatalogue` exists
for this and is the only way paths are taken there.

**`WhisperKitConfig(download: false)` with no `modelFolder` never looks anywhere.**
It does not fall back to the variant name — it leaves the folder unset and fails
at load. Fetching belongs to the catalogue, where there is a progress bar, so the
transcriber always passes the folder explicitly.

## Conventions

* Swift 6 language mode, strict concurrency. Cross-actor types are `Sendable`;
  mutable shared state is an `actor`.
* No `!` force unwraps and no `try!` outside tests. A failure that cannot be
  handled is still reported.
* Errors are typed enums per port, in the caller's terms. An adapter maps its
  framework's failures onto them and keeps the original text rather than
  dropping it.
* Comments say *why*. Anything a reader would rediscover by debugging — a
  framework that lies, an order that matters — is written down at the place it
  matters.
* Tests use Swift Testing (`import Testing`, `@Test`). The domain is tested
  with fakes for every port and reaches neither the network, a process, nor a
  sound device.
* Public API carries doc comments. Internal helpers do not need them.
