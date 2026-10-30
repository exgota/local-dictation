# For agents reviewing this repository

A review of this repository needs no build and no run. The specification, screenshots, model signatures and measured
numbers are in the repository as text and images.

## Read in this order

1. [docs/SPEC.md](docs/SPEC.md): what the app does, its architecture and threads, the model, the measured numbers,
   screenshots of every screen, and open questions.
2. [docs/measurements/](docs/measurements/): raw benchmark, self-test, doctor and live test output.
3. [docs/model/](docs/model/): Core ML metadata for each model component and the pinned file manifest.
4. The code, starting with the hot paths:
   - `Sources/LocalDictation/HotkeyEventTap.swift`: the event tap callback, which must stay free of allocation and
     locks.
   - `Sources/DictationEngine/StreamingTranscription.swift`: the worker that runs voice activity detection (VAD) and
     cuts chunks.
   - `Sources/DictationEngine/SpeechTranscriber.swift`: how the model runs and which compute unit runs each component.
   - `Sources/LocalDictation/AudioRecorder.swift`: capture.
   - `Sources/LocalDictation/TextInserter.swift` and `Sources/DictationCore/ClipboardPasteTransaction.swift`:
     insertion and clipboard handling.
   - `Sources/LocalDictation/SettingsWindow.swift` and `HeadsUpDisplay.swift`: the interface.

The model weights (1.2 GB) are not in the repository. They are public at
https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro/tree/4b5c51e04aa8d16dda9ecdff71bc29f7360149e4/coreml.
FluidAudio, the Swift package that wraps the Core ML models, is pinned at
https://github.com/FluidInference/FluidAudio/tree/a00964e1aa8eff99c4bce80bc9c8ff2d4dd1568d.

## If you can run things

```sh
swift test                                  # unit tests, no model needed
./build_application.sh                      # builds and installs to ~/Applications (Apple Silicon, macOS 15+)
"$HOME/Applications/Local Dictation.app/Contents/MacOS/LocalDictation" --selftest Tests/fixtures/synthetic
```

`--selftest` needs the speech model, which you download from the setup window of the installed app, and the fixture
WAV files, which the repository does not hold.

[BUILD.md](BUILD.md) covers signing and tests, including how to generate the fixtures. The end-to-end harness is
`Tests/EndToEnd/run_scenarios.sh`. It plays speech through the speakers into the microphone, drives the installed app
with synthetic key events, and sets the system output volume to 60 while it runs. Its header lists the requirements:
the installed app, TextEdit, the compiled `post_keyboard_events` helper and, for `chrome_paste`, Google Chrome.
