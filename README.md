# Local Dictation

[![Continuous integration](https://github.com/exgota/local-dictation/actions/workflows/continuous-integration.yml/badge.svg)](https://github.com/exgota/local-dictation/actions/workflows/continuous-integration.yml)

**Talk to Claude, ChatGPT or your terminal. Your words land at the cursor, and your voice stays on your Mac.**

Press Fn, say the whole prompt, press Fn again. Messaging apps like Slack get clean sentences, terminals get the words as recognized,
and known password managers get nothing.

**[Download for Mac](https://github.com/exgota/local-dictation/releases/latest/download/Local-Dictation.dmg)** · free
and open source, no account · Apple silicon, macOS 27 or later, English · [install steps](#install)

<img src="docs/screenshots/hud-listening.png" width="300" alt="The moon indicator Local Dictation shows while it listens">

<sub>The moon appears while it listens, and a small waveform waits in the menu bar the rest of the time.</sub>

| Result | What it measures |
|---|---|
| **0.14 to 0.25 s** | from your second Fn press to the finished text |
| **0.8 to 2.1%** | word error rate on recorded test speech |

<sub>Measured on version 1.0.1 on one Mac. [docs/SPEC.md](docs/SPEC.md) shows how.</sub>

## Where your words go

| Where you are | You say | What arrives |
|---|---|---|
| Slack | "Let's send it tomorrow, scratch that, send it today." | Send it today. |
| A terminal, with a correction for "cloud code" | "open cloud code" | open Claude Code |
| A known password manager | anything | nothing is typed |

<img src="docs/screenshots/history-dark.png" width="600" alt="History, showing dictations typed into T3 Code, Chrome, Messages, Claude and Slack">

<sub>The History window, after a day of dictating into T3 Code, Chrome, Messages, Claude and Slack.</sub>

- **It transcribes while you talk.** A long prompt is mostly written by the time you stop, so there is little to wait
  for.
- **Messaging apps get light cleanup.** In Slack, Discord, Telegram, WhatsApp and Messages, "um" and similar fillers
  go, "comma" and "new line" become punctuation, sentences get capitals, and "scratch that" deletes the last sentence
  you said.
- **Teach it your words.** Corrections are your own rules for names and terms it keeps getting wrong.
- **It leaves your clipboard alone.** The text is typed where you were working, and the clipboard is put back the way
  it was.
- **Your words survive a missed field.** If there is nowhere to type, they wait on the clipboard for ⌘V, and Paste
  last text (⌥⇧V by default) brings back your last dictation later.

<img src="docs/screenshots/corrections-dark.png" width="420" alt="Corrections turning cloud code into Claude Code">

<sub>Corrections: write a rule once, and with Apply corrections on, later dictations use it.</sub>

## Install

### Get the app

You need an Apple silicon Mac with macOS 27 or later, and about 2.5 GB free while the speech model installs. It takes
about 1.3 GB after that. Dictation is English only.

1. Download [`Local-Dictation.dmg`](https://github.com/exgota/local-dictation/releases/latest/download/Local-Dictation.dmg),
   open it, and drag Local Dictation onto the Applications folder.
2. Open Local Dictation from Applications. The app is not notarized by Apple, so the first time, macOS says it cannot
   verify the app. That is expected. Click Done.
3. Open System Settings → Privacy & Security, scroll to Security, and click Open Anyway next to Local Dictation. Confirm
   with your password.

<details>
<summary>Opened it from the disk image or Downloads?</summary>

It offers to move itself to Applications. Choose Move to
Applications, and it moves and reopens. `Local-Dictation.zip` on the same release holds the same app.

</details>

### First launch

Setup takes you through four steps, one at a time:

1. **Microphone**, so it can hear you.
2. **Accessibility**, so it can notice the Fn key and type into other apps.
3. **The speech model**, a one-time 1.2 GB download from
   [Hugging Face](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro). The download fills the bar to 80%, then
   "Preparing for this Mac" finishes it in about a minute. At "Ready, 100%" you can dictate. If the download stops,
   choose Try Again.
4. **Try it.** Press Fn, say something, and press Fn again. Your words appear in the setup window.

After that the app lives in the menu bar as a waveform. Click it to start dictation, paste your last dictation, open
history, pause the shortcuts or open Settings.

## Everyday use

- **Fn starts and stops a dictation.** Escape cancels the one in progress. Settings offers hold to talk and other keys.
- **You can start right after launch.** If the speech model is still loading when you press Fn, the app records anyway
  and types your words once the model is ready.
- **Other apps get the same cleanup if you want it.** Turn on Remove fillers and format text in Settings, or set any
  app under App Exceptions. Terminals, code editors and password managers keep their defaults unless you change them
  there.
- **Corrections** live in Settings: turn on Apply corrections and choose Edit Corrections….
- **History and text files are off by default.** History shows your dictations with Copy and Add Correction. Text files
  go in the Transcripts folder on your Desktop by default, one folder per day, as Markdown.

<details>
<summary><b>When it cannot type</b></summary>

- **No text field, or focus moved:** the moon folds into a copy icon and the text goes on the clipboard. Press ⌘V. The
  icon rises away after 5 seconds, or sooner if you paste. The text stays on the clipboard until you copy something
  else. If the app could not confirm the text was typed, check before pasting, because it may already be there.
- **The model is not ready:** if it fails to load, or is still not ready two minutes after you start recording, a sound
  plays and the recording stays in memory until the model recovers, you cancel it or you quit.
- **A lock on the menu bar icon:** another app, such as a password manager or Terminal's Secure Keyboard Entry, is
  protecting what you type, so Local Dictation cannot notice Fn. Hold the pointer over the icon to see which app it is,
  when the app can tell.

</details>

## Privacy

Speech is recognized on your Mac. Local Dictation does not upload your audio or text, and it does not save recordings.
The microphone is on only while you dictate.

Transcripts are saved only if you turn on history (kept in `~/Library/Application Support/LocalDictation/`) or text
files. Clearing history does not delete text files. Your last dictation stays in memory until a newer one with words
replaces it or you quit, so you can paste it again. Once text is typed or pasted into another app, that app decides what
happens to it.

The app goes online for two things: downloading the speech and voice activity models from Hugging Face, and checking
GitHub for updates and downloading them.

## Updates

The app checks GitHub for new versions on its own. When one is ready, you see an update alert, or an Install update…
item in the menu if the alert would have interrupted you. Nothing installs until you choose Install Update. Versions
before 1.1 cannot check, so install the latest version by hand once.

## Under the hood

Local Dictation runs Underdog Bark 3.0 Pro, a Parakeet speech model, on the Mac with Core ML.
[docs/SPEC.md](docs/SPEC.md) has the architecture, the model and every measurement with its source.

## Build from source

You need Xcode with the Swift 6.2 toolchain or later.

```sh
git clone https://github.com/exgota/local-dictation.git
cd local-dictation
./build_application.sh
```

The script builds, signs and installs the app to `~/Applications/Local Dictation.app`. It signs with a code-signing
identity named Local Dictation Development when your keychain has one. Without it the app is signed ad hoc, and macOS
asks for its permissions again after every rebuild. [BUILD.md](BUILD.md) shows how to create the identity, and covers
releases, tests and benchmarks. [AGENTS.md](AGENTS.md) gives a reading order for reviewers.

## Licenses

The code is under the [MIT License](LICENSE). Underdog Bark 3.0 Pro and the models it derives from are CC BY 4.0. Silero
VAD is MIT, FluidAudio is Apache 2.0 and Sparkle is MIT. See [Packaging/NOTICE](Packaging/NOTICE).
