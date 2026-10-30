# Start and stop sounds

The app ships `Start.wav` and `Stop.wav` in `Packaging/Cues`, and `build_application.sh` copies them into
the bundle at `Contents/Resources/Cues`. They are synthesised, not sampled from anyone, so they can ship
in a public release.

`Tools/GenerateCues.swift` rebuilds both files. `swift -O Tools/GenerateCues.swift` from the repository
root overwrites them. The output is deterministic: the noise comes from a fixed-seed generator, so the
same toolchain writes byte-identical files. Each cue is a short dry tone traced from per-cycle
measurements, followed by a synthetic reverberant tail. A soft limiter holds the first few milliseconds at -0.1 dBFS,
so the rest of each cue is 6 dB louder than peak normalization alone would make it. The files are 44.1 kHz stereo with
24-bit samples, because the tail falls below the 16-bit noise floor.

Measured by `Tools/MeasureCues.swift`:

| Property | Start | Stop |
|---|---|---|
| Fundamental | 1625 Hz | 1005 Hz |
| Attack | Broadband click, energy to 16 kHz; peak in 2 ms | Duller, energy mostly 800 to 1100 Hz; peak in 3 ms |
| Sample peak | -0.1 dBFS | -0.1 dBFS |
| Decay | -39 dB at 100 ms, -96 dB at 1.5 s | -39 dB at 100 ms, -86 dB at 1.5 s |
| Length | 2.0 s, ends silent | 2.0 s, ends silent |

The tool prints the same measurements for one cue, or for two side by side:

```sh
swift -O Tools/MeasureCues.swift Packaging/Cues/Start.wav Packaging/Cues/Stop.wav
```

`CuePlayer` plays the bundled `Cues/Start.wav` and `Cues/Stop.wav`. If a bundled file does not load, it plays
`Pop.aiff` (start) or `Bottle.aiff` (stop) from `/System/Library/Sounds` instead.

The Sounds slider scales both cues, and all the way down turns them off. The default is the midpoint, 0.5, which is
6 dB below the files' own level.
