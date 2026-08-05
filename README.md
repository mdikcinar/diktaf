# Diktaf

Press a key, talk, press it again. macOS turns the recording into text with the
recogniser it already has, a local Claude agent cleans it up by rules you wrote,
and the result lands in your clipboard and is pasted into whatever window you
were typing in.

No API keys. No models to download. Nothing leaves the machine: the transcription
is Apple's on-device recogniser, and the cleanup runs through the `claude` CLI
you are already signed in to.

```sh
Scripts/install.sh      # builds Diktaf.app, installs it, starts it at login
```

| What | How |
| --- | --- |
| Start / stop dictating | `Ctrl+Alt+Space`, or the menu bar icon |
| Throw the recording away | `Ctrl+Alt+D` |
| Ask the agent instead of pasting | `Ctrl+Alt+A` |

`Ctrl+Space` is not among them: on macOS that key belongs to the input source
switcher and never reaches an application. Every combination is yours to change
in Settings.

## What it does

**Dictation.** The system recogniser runs on this Mac, streaming words as you
say them. The indicator shows the text arriving so you can see it is hearing you.

**Cleanup rules.** Rules are your own sentences — *drop the filler words*, *keep
my wording*, *no markdown* — each one switchable, plus a free-form instruction
for anything else. They become the prompt handed to the local agent. Cleanup can
be switched off, in which case the raw transcript is pasted. If the agent fails
or takes too long, the raw transcript is pasted anyway: a dictation that arrives
uncleaned beats one that disappears.

**Agent.** A dictation sent to the agent becomes a question rather than text to
paste. The reply is shown, and the conversation can be continued or cleared.

## Languages

Diktaf transcribes with the model behind macOS's own dictation, which covers 54
languages — Turkish, Russian, Polish, Arabic, Hindi, the Nordic languages and the
rest. Pick yours in Settings → General; a ✓ beside a language means its model is
already on this Mac, and anything else offers a Download and says when it is
ready. Nothing is sent anywhere either way: the recogniser runs here.

(macOS has a second recogniser, the one meant for transcribing recordings. It
covers 30 languages and has no Turkish. Diktaf does not use it, and
[ARCHITECTURE.md](ARCHITECTURE.md) says why in more detail.)

## Requirements

* macOS 26 or later. Diktaf uses the `SpeechAnalyzer` API introduced there, which
  is both the best on-device recogniser Apple ships and the reason there is no
  earlier fallback.
* Xcode 26 (or its command line tools) to build.
* The [`claude` CLI](https://claude.com/claude-code), signed in, for cleanup and
  the agent. Without it, dictation still works and pastes the raw transcript.

macOS will ask for the microphone and for speech recognition the first time you
dictate. Pasting needs one more that it cannot ask for: System Settings → Privacy
& Security → Accessibility → allow Diktaf. Until it has been allowed, Diktaf says
so in the menu bar — worth knowing, because told to press a key it has not been
allowed to, macOS reports that it did and the text arrives nowhere.

## Building and hacking on it

```sh
swift build                  # the package
swift test                   # the domain and the agent adapters, offline
Scripts/build-app.sh          # assembles build/Diktaf.app
```

The layering is the point, and [ARCHITECTURE.md](ARCHITECTURE.md) is worth
reading before changing anything: `DiktafCore` holds the domain and imports
Foundation and nothing else, the platform lives behind protocols in
`DiktafCore/Ports`, and macOS is one set of adapters. Windows is not supported,
but it is a target away rather than a rewrite — which is the only reason the
seam exists.
