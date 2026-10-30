# Building Local Dictation

This page is for anyone who builds, signs or tests the app from source. It assumes Apple Silicon, macOS 15 or later,
and Xcode with the Swift 6.2 toolchain or later. To use the app without building it, see the prebuilt copy section of
[README.md](README.md).

```sh
./build_application.sh
```

The script builds the release product, assembles `dist/Local Dictation.app`, signs it, verifies the signature and
installs it to `~/Applications/Local Dictation.app`.

## Cue sounds

`build_application.sh` copies `Packaging/Cues/Start.wav` and `Stop.wav` into the bundle. Both files are generated.
Change the generator and run it. Do not edit the WAV files by hand:

```sh
swift -O Tools/GenerateCues.swift
```

The measurements behind them are in `docs/audio/README.md`.

## Application icon

`Packaging/AppIcon.icns` is generated too. Change it through the generator:

```sh
swift Tools/GenerateApplicationIcon.swift
```

## Signing identity

Every build that finds the certificate below is signed with it, so macOS keeps the Microphone and Accessibility grants
across rebuilds. The certificate is self-signed:

| Field | Value |
|---|---|
| Common name | Local Dictation Development |
| Keychain | login |
| Certificate SHA-1 | 08C3908B94C45A28C421181CAD0B367880EBCE86 |
| Configuration | `Packaging/signing-certificate.cnf` (code signing extended key usage, self-signed) |

`build_application.sh` looks the identity up by common name. Without it the app is signed ad hoc, and macOS asks for
the permissions again after every build. To recreate the identity on another Mac:

1. Generate a certificate and key from `Packaging/signing-certificate.cnf` with OpenSSL.
2. Import the certificate and key into the login keychain.
3. Trust the certificate for code signing.

At each launch the app records the SHA-1 digest of its signing certificate. If the digest differs from the one recorded
at the previous launch, Settings shows a banner and `--doctor` warns, because the grants for the old identity no longer
apply.

## Install location

`~/Applications` is a supported location. The app warns about its location only when it runs quarantined (its bundle
carries the `com.apple.quarantine` attribute) or translocated (macOS runs it from a randomized path under
`AppTranslocation`). These cases arise when the app is opened from a disk image or from Downloads, and in both macOS
withholds permissions.

## Tests

```sh
swift test                                   # unit tests
"$HOME/Applications/Local Dictation.app/Contents/MacOS/LocalDictation" --selftest Tests/fixtures/synthetic
"$HOME/Applications/Local Dictation.app/Contents/MacOS/LocalDictation" --doctor
```

`swift test` needs no speech model. The other two commands run the installed app, so run `./build_application.sh`
first. `--selftest` also needs the speech model, which you download from the setup window, and the WAV files of the
fixture directory you give it.

`Tests/fixtures/synthetic/generate_synthetic_fixtures.py` generates the synthetic fixtures with `say`. The repository
holds their expected transcripts but not their WAV files. A `SYNTHETIC` file in the directory marks every result from
them @weak, because generated speech is not proof.

To record real fixtures, open Settings → About and hold Option. A Developer section appears with Record fixture…, which
records twelve scripted takes into `~/Library/Application Support/LocalDictation/Fixtures`. `--selftest` reads that
folder when you give it no directory.

The memory check streams recordings through the pipeline in 20 ms pieces at up to 20 times real time. It prints the
memory footprint after the model loads, then for each file the maximum footprint sampled while streaming and the
footprint at the end. The paths point into the installed speech model, and the last command also reads
`Tests/fixtures/synthetic/06-quiet-long.wav`, one of the synthetic fixtures:

```sh
say -f Tests/fixtures/memory/long-15min.txt -o /tmp/long-15min.aiff
afconvert -f WAVE -d LEF32@16000 -c 1 /tmp/long-15min.aiff Tests/fixtures/memory/long-15min.wav
swift build -c release --product TranscriptionBenchmark
MODELS="$HOME/Library/Application Support/LocalDictation/Models"
.build/release/TranscriptionBenchmark stream "$MODELS/4b5c51e04aa8d16dda9ecdff71bc29f7360149e4/compiled" \
  "$MODELS/4b5c51e04aa8d16dda9ecdff71bc29f7360149e4/packages/parakeet_v3_vocab.json" \
  "$MODELS/silero-vad/b419383c55c110e2c9271fa6ee0ea83d03c70d96/silero-vad-unified-256ms-v6.2.1.mlmodelc" \
  Tests/fixtures/synthetic/06-quiet-long.wav Tests/fixtures/memory/long-15min.wav
```
