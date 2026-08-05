# Architecture

Diktaf is a menu bar dictation app for macOS. Press a key, talk, press it
again: the recording is turned into text by the speech recogniser already in
macOS, a local Claude agent cleans it up according to rules you wrote, and the
result lands in your clipboard and is pasted into whatever window you were
typing in. A second key sends what you said to the agent as a question instead.

No API keys, no models to download, no network: the transcription is Apple's
on-device recogniser and the cleanup is the `claude` CLI you already have
signed in.

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
        ┌───────────────┴───────────┬──────────────┐
        │  DiktafMac                │ DiktafClaude │  adapters
        │  Speech, AppKit, Carbon   │ Process      │
        └───────────────┬───────────┴──────┬───────┘
                        │  conform to      │
        ┌───────────────┴──────────────────┴───────┐
        │  DiktafCore      domain + ports          │  Foundation only
        │  no platform, no processes, no UI        │
        └──────────────────────────────────────────┘
```

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
| `DiktafClaude` | the `claude` CLI as a subprocess | Foundation, DiktafCore |
| `Diktaf` | SwiftUI, menu bar, settings, overlay, wiring | everything |

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
