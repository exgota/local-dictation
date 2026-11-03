# Building Local Dictation

This page is for anyone who builds, signs or tests the app from source. It assumes Apple Silicon, macOS 27 or later,
and Xcode with the Swift 6.2 toolchain or later. To use the app without building it, see the prebuilt copy section of
[README.md](README.md).

```sh
./build_application.sh
```

The script builds the release product, assembles `dist/Local Dictation.app`, signs it, verifies the signature and
installs it to `~/Applications/Local Dictation.app`. The moon shader compiles from source when the app launches, before
any moon window can appear.

The app bundle requires macOS 27.0 through `LSMinimumSystemVersion`. The package uses `.macOS(.v26)`, the newest
named platform supported by the current Swift 6.3.3 toolchain; this does not lower the app's supported OS version.

To measure renderer initialization and the first offscreen setup frame in a fresh process without starting app services:

```sh
swift build -c release -Xswiftc -DMOON_DIAGNOSTICS
.build/release/LocalDictation --measure-moon-startup
```

A fresh process does not imply a cold system shader cache. The timing flag is excluded from ordinary release builds.

## Setup comparison renders

The debug build can render the production setup view without creating permission, model, recording or command
services. It does not install or activate the app, request permissions, download a model or start dictation:

```sh
swift build
.build/debug/LocalDictation --render-setup /tmp/local-dictation-setup-renders
```

For an optimized diagnostics build, use `swift build -c release -Xswiftc -DMOON_DIAGNOSTICS` and the release binary.
The command is excluded from ordinary release builds. The directory receives 13 PNGs: microphone, microphone denied,
Accessibility, Accessibility waiting, download at 0/25/50/75/99 percent, download failed, and try-it empty/listening/text.
All use dark appearance at 2 pixels per point. The actual setup shader drawing is pinned to 1.7 seconds and a settled
shape transition, with completion phase 1.25 (400 ms into the ring) and failed-download progress at 37%. Each view is
created directly in its final state, so no cross-fade is sampled. The text capture contains a synthetic fixture. These offscreen captures establish layout and drawing, not
live permission handoff, animation timing, microphone capture or speech recognition.

The reference `SetupPrototype` target accepts the same command and writes the same filenames. Its layout remains
unchanged, including its fixed action area, which clips Done in the try-it captures. Production allows this area to
grow so the real text field and Done both fit. Compare the moon and copy at their original coordinates; production's
try-it window is taller for this reason.

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
at the previous launch, setup shows a secondary line and `--doctor` warns, because the grants for the old identity
no longer apply.

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

For real fixtures, supply mono 16 kHz WAV recordings and matching `.expected.txt` files to `--selftest DIRECTORY`.
With no directory, `--selftest` reads `~/Library/Application Support/LocalDictation/Fixtures`. Diagnostics remain
available from the command line; Settings contains no developer controls.

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

## Automatic updates and releases

Sparkle 2.10.1 is pinned in `Package.swift`. The app carries the `com.apple.security.cs.disable-library-validation`
entitlement: the self-signed identity has no Apple team ID, and the hardened runtime otherwise refuses to load the
embedded Sparkle framework ("different Team IDs"). Sparkle's own helpers load only system libraries and need no
exception. The build embeds its framework, XPC services and helpers, signing inside out with the existing identity
lookup and ad hoc fallback. Run `build_application.sh` only in the logged-in desktop session: it **installs** the app,
and SSH cannot see the signing identity that preserves Microphone and Accessibility grants. Over SSH, use `swift build`
and `swift test`.

Scheduled checks use Sparkle's gentle reminder delegate. Near launch, Sparkle can show its standard alert in
immediate focus. Otherwise Install update… appears at the top of the menu's second command group, above Open at login.
One notification is posted only with existing notification authorization; an update never prompts for that permission.
The menu command and notification click both call `checkForUpdates` to focus the standard alert. User attention or
session completion clears the menu item and any pending or delivered notification. The menu header and pill stay
unchanged.

Updates are signed with an EdDSA key. Its public half is `SUPublicEDKey` in `Packaging/Info.plist`. The private half
lives in the release Mac's login keychain, where `generate_appcast` reads it. To sign releases on another Mac, import
the maintainer's offline copy there with Sparkle's `generate_keys -f`. Source builds without a valid public key
silently skip updater startup.

For each release, increase `CFBundleShortVersionString` and `CFBundleVersion` (1.1 starts at build 2), add its version
section to `CHANGELOG.md`, and run the build script in the desktop session. Verify the signed bundle, then stage it:

```sh
codesign --verify --deep --strict "dist/Local Dictation.app"
mkdir -p release-archives
ditto -c -k --sequesterRsrc --keepParent "dist/Local Dictation.app" release-archives/Local-Dictation-1.1.1.zip
python3 Tools/generate_appcast.py release-archives \
  --download-url-prefix https://github.com/exgota/local-dictation/releases/download/v1.1.1/
```

This example assumes 1.1.1/build 3. Stage only archives from 1.1 onward, with unique build numbers. The script creates
HTML notes from each version's changelog and signs the appcast using Sparkle's keychain key. The notes remain in
the appcast, but `SUShowReleaseNotes` is false in `Packaging/Info.plist`, so the standard update alert shows its
message and buttons without a release-notes box. The script preserves old entries, creates no deltas, and uploads
nothing. Before separately publishing, review the appcast and signatures. Every archive URL must remain downloadable. The latest GitHub release must contain `appcast.xml`; also provide `Local-Dictation.zip`
for the README's installation path.

Before shipping, complete a real desktop update test:

1. In an isolated test checkout, use the same key and signing identity for 1.1/build 2 and a throwaway 1.1.1/build 3.
   Before signing, set both test plists' `SUFeedURL` to `http://127.0.0.1:8765/appcast.xml` and `SUDefaultsDomain` to a
   fresh test-only domain such as `com.exgota.LocalDictation.UpdateTest.20261103`.
2. Intentionally quit the normal app. Build and archive both test versions, then restore the signed 1.1 bundle as the
   installed test copy. Add temporary 1.1.1 changelog notes and generate the feed with
   `--download-url-prefix http://127.0.0.1:8765/`.
3. Serve it with `python3 -m http.server 8765 --bind 127.0.0.1 --directory release-archives`. Launch test 1.1 and confirm
   there is no permission prompt. Install through the standard alert; verify relaunch as 1.1.1/build 3, the deep code
   signature, and unchanged Microphone and Accessibility grants. Also check a scheduled update after the launch
   focus window while Chrome is frontmost: no hidden alert, one Install update… above Open at login, and one notification
   if already authorized. With notifications denied or undecided, check that the menu reminder still appears without
   a permission prompt. Exercise both reminder entry points, verify the alert gains focus, and verify both reminders
   disappear on attention and session completion. Confirm the alert has no release-notes box even when the appcast
   contains notes.
   For repeat tests, delete only the test domain's `SULastCheckTime` before launch to make the check due.
4. Quit the test app, stop the server, and restore the intended signed bundle. Discard test feed/version overrides;
   do not publish the throwaway release.

Desktop checks must also cover real recording during loading, both stop/readiness orders, cancellation, another
recording, focus movement, sleep, microphone interruption and Reduce Motion. Unit tests use synthetic audio and model
streams; they do not prove live capture, model latency, insertion, keychain access or update installation.
