// Synthesises the start and stop cues from parameters alone and writes Packaging/Cues/Start.wav and Stop.wav.
//
//   swift -O Tools/GenerateCues.swift        (about 2 s; without -O the interpreter takes close to a minute)
//
// Each cue is 2.0 s of 44.1 kHz stereo, built in four steps from the design targets listed above each cue below:
//   1. A dry tone, which is the cue without reverberation, 38 ms long for the start cue and 32 ms for the stop cue. It
//      has one sine partial whose amplitude and frequency follow breakpoint curves, faint partials (five for the start
//      cue, four for the stop cue), and a short burst of band-passed noise for the click. All of it is high-passed at
//      300 Hz.
//   2. For the stop cue only, a low thump with falling pitch. It bypasses the reverb, so the tail carries 50 dB less
//      low end than the head.
//   3. A reverberant tail: the dry tone convolved with a synthetic impulse response for each channel. Each impulse
//      response is seeded noise under a two-slope decay, fast for the first 300 ms and slow after. The left and right
//      responses share part of their noise, mostly at first and little later, so a cue starts near mono and ends with
//      a left/right correlation under 0.2. A narrow-band tail this short gives a correlation that varies by about 0.3
//      from seed to seed, so the seeds are arbitrary and were not chosen to hit those numbers.
//   4. The sum, scaled so that the louder channel would peak 6 dB over -0.1 dBFS, then soft limited to -0.1 dBFS. The
//      limiter acts only on the first few milliseconds, so the rest of the cue is twice the level of a plain peak
//      normalization and the volume slider has that much more range.
//
// The output is deterministic: the noise comes from a fixed-seed SplitMix64 generator and the arithmetic is plain
// sequential Double math, so the same toolchain writes byte-identical files.

import Foundation

let sampleRate = 44_100.0
let frameCount = 88_200  // 2.0 s

/// A curve given as (milliseconds, value) points, linear between points and held flat outside them.
struct Breakpoints {
    let points: [(Double, Double)]
    func value(atMilliseconds time: Double) -> Double {
        guard time > points[0].0 else { return points[0].1 }
        for (a, b) in zip(points, points.dropFirst()) where time <= b.0 {
            return a.1 + (b.1 - a.1) * (time - a.0) / (b.0 - a.0)
        }
        return points[points.count - 1].1
    }
}

/// A sine partial. `decibels` is the level against an amplitude of 1, the peak of the main partial; `frequency` is in
/// hertz.
struct Partial {
    let frequency: Breakpoints
    let decibels: Breakpoints
    var phase = 0.0
}

struct Reverberation {
    let predelayMilliseconds: Double
    let rampMilliseconds: Double     // length of the fade-in after the predelay, applied as a squared ramp
    let earlyDecay: Double           // dB per second over roughly the first 300 ms
    let lateDecay: Double            // dB per second after that
    let lateLevel: Double            // dB of the slow component relative to the fast one at the start of the response
    let gain: Double                 // linear gain of the wet signal against the dry tone
    let earlyCorrelation: Double     // share of energy common to left and right at the start of the response
    let lateCorrelation: Double      // the same share once the tail is diffuse
    let correlationMilliseconds: Double  // time constant of the move from early to late correlation
    let seed: UInt64
}

/// A sine whose pitch falls exponentially from `startFrequency` towards `endFrequency`, starting on a negative lobe.
struct Thump {
    let startFrequency: Double
    let endFrequency: Double
    let glideMilliseconds: Double    // time constant of the pitch fall
    let amplitude: Double            // linear, against the main partial's peak of 1
    let decayMilliseconds: Double    // time constant of the amplitude decay
}

/// Band-passed noise under an exponential decay.
struct Click {
    let amplitude: Double
    let centreHertz: Double
    let decayMilliseconds: Double
    let seed: UInt64
}

struct CueDesign {
    let name: String
    let partials: [Partial]
    let click: Click
    let thump: Thump?
    let highpassHertz: Double        // second-order Butterworth on the dry tone and therefore on the reverb
    /// Cutoff for the reverb alone, which is thinner than the dry tone: two second-order sections at Q 0.5 in cascade.
    let wetHighpassHertz: Double
    let reverberation: Reverberation
    let dryMilliseconds: Double      // the dry tone is silent after this
}

// Start cue. Design targets:
//   pitch 1622 Hz after 6 ms; the first 3 ms sit near 1510 Hz and overshoot to 1690 Hz at 4.4 ms
//   a second partial near 1415 Hz, 15 dB under the fundamental in the first 40 ms, and a trace at 1060 Hz
//   peak at 2 ms; -8 dB notch at 4.5 ms; -12 dB at 10 ms, -21 dB at 20 ms, dry tone gone by about 30 ms
//   faint partials at 3.91, 5.16 and 6.55 kHz, 41 to 47 dB under the fundamental in the first 40 ms
//   tail: -37 dB at 50 ms, -66 dB at 300 ms, -108 dB at 1.9 s (50 ms RMS against the first 5 ms), so about
//   -120 dB/s until 300 ms and -26 dB/s after; third-octave bands at 630 and 800 Hz 15 to 20 dB lower than the head
//   predicts, hence the 900 Hz high-pass on the reverb
//   L/R correlation 0.998 over 0-30 ms, 0.67 over 30-200 ms, 0.12 over 200-1500 ms
let start = CueDesign(
    name: "Start",
    partials: [
        Partial(
            frequency: Breakpoints(points: [(0, 1505), (2, 1525), (3.5, 1610), (4.5, 1690), (5.5, 1626), (8, 1630), (30, 1622)]),
            decibels: Breakpoints(points: [(0, -60), (0.5, -9), (1.0, -2), (2.0, 0), (3.0, -1), (4.5, -8), (6, -6), (8, -10),
                                           (12, -13), (16, -15), (20, -20), (23, -24), (26, -29), (34, -31), (36, -45), (38, -70)])),
        Partial(frequency: Breakpoints(points: [(0, 1415)]), decibels: Breakpoints(points: [(0, -60), (1, -20), (12, -32), (25, -60)])),
        Partial(frequency: Breakpoints(points: [(0, 1060)]), decibels: Breakpoints(points: [(0, -60), (1, -38), (15, -50), (25, -70)])),
        Partial(frequency: Breakpoints(points: [(0, 3911)]), decibels: Breakpoints(points: [(0, -60), (1, -38), (15, -52), (30, -80)])),
        Partial(frequency: Breakpoints(points: [(0, 5164)]), decibels: Breakpoints(points: [(0, -60), (1, -43), (12, -58), (25, -80)])),
        Partial(frequency: Breakpoints(points: [(0, 6549)]), decibels: Breakpoints(points: [(0, -60), (1, -42), (10, -58), (20, -80)])),
    ],
    click: Click(amplitude: 0.012, centreHertz: 6000, decayMilliseconds: 8, seed: 0x5354_4152_5400_0003),
    thump: nil,
    highpassHertz: 300,
    wetHighpassHertz: 900,
    reverberation: Reverberation(predelayMilliseconds: 8, rampMilliseconds: 20, earlyDecay: 120, lateDecay: 24, lateLevel: -29,
                                 gain: 0.0066, earlyCorrelation: 1.0, lateCorrelation: 0.05,
                                 correlationMilliseconds: 80, seed: 0x5354_4152_5400_0001),
    dryMilliseconds: 38)

// Stop cue. Design targets:
//   pitch 1003 Hz in the body; the first 6 ms sit near 960 Hz, overshoot to 1060 Hz at 9.7 ms, sag to 950 Hz at 28 ms
//   peak at 3 to 4 ms; -12 dB at 10 ms, a -12 to -19 dB shelf until 27 ms, then a cut to the reverb by 30 ms
//   faint partials at 1437, 1862 and 2927 Hz, 39 to 42 dB under the fundamental in the first 40 ms
//   a low thump: a negative lobe peaking near 5 ms, a longer positive lobe near 11 ms, gone by 25 ms, so its pitch falls
//   from about 90 Hz; -33 dBFS peak below 250 Hz; third-octave bands 40 to 125 Hz at -34 to -41 dBFS over 0-30 ms
//   tail: -32 dB at 50 ms, -66 dB at 300 ms, -101 dB at 1.9 s, so about -135 dB/s until 300 ms and -22 dB/s after
//   L/R correlation 0.994 over 0-30 ms, 0.43 over 30-200 ms, 0.17 over 200-1500 ms
let stop = CueDesign(
    name: "Stop",
    partials: [
        Partial(
            frequency: Breakpoints(points: [(0, 958), (6, 965), (8.5, 1015), (9.7, 1055), (11.5, 1022), (13.5, 990), (17, 1000),
                                            (20, 1020), (23, 1007), (26, 990), (29, 955)]),
            decibels: Breakpoints(points: [(0, -60), (0.5, -17), (1.0, -9), (1.5, -5), (2.0, -3), (3.0, 0), (4.0, 0), (6, -2), (8, -6),
                                           (10, -12), (12, -12), (16, -13), (20, -19), (26, -19), (28, -25), (30, -40), (32, -70)])),
        Partial(frequency: Breakpoints(points: [(0, 1437)]), decibels: Breakpoints(points: [(0, -60), (1, -41), (20, -50), (30, -80)])),
        Partial(frequency: Breakpoints(points: [(0, 1862)]), decibels: Breakpoints(points: [(0, -60), (1, -45), (15, -58), (28, -80)])),
        Partial(frequency: Breakpoints(points: [(0, 2927)]), decibels: Breakpoints(points: [(0, -60), (1, -32), (8, -46), (20, -75)])),
        Partial(frequency: Breakpoints(points: [(0, 2800)]), decibels: Breakpoints(points: [(0, -60), (1, -38), (8, -52), (20, -75)])),
    ],
    click: Click(amplitude: 0.015, centreHertz: 4000, decayMilliseconds: 8, seed: 0x5354_4F50_0000_0003),
    thump: Thump(startFrequency: 90, endFrequency: 30, glideMilliseconds: 10, amplitude: 0.03, decayMilliseconds: 12),
    highpassHertz: 300,
    wetHighpassHertz: 250,
    reverberation: Reverberation(predelayMilliseconds: 8, rampMilliseconds: 10, earlyDecay: 165, lateDecay: 22, lateLevel: -31,
                                 gain: 0.0067, earlyCorrelation: 0.95, lateCorrelation: 0.17,
                                 correlationMilliseconds: 40, seed: 0x5354_4F50_0000_0002),
    dryMilliseconds: 32)

/// SplitMix64, returning doubles uniform in [-1, 1).
struct NoiseGenerator {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 52) - 1
    }
}

func renderDryTone(_ design: CueDesign) -> [Double] {
    let length = Int(design.dryMilliseconds / 1000 * sampleRate)
    var partials = design.partials
    var noise = NoiseGenerator(state: design.click.seed)
    var clickFilter = Biquad.bandpass(centre: design.click.centreHertz, q: 0.7)
    var tone = [Double](repeating: 0, count: length)
    for index in 0..<length {
        let milliseconds = Double(index) / sampleRate * 1000
        for p in partials.indices {
            // Integrate frequency into phase so the glides stay continuous.
            partials[p].phase += 2 * .pi * partials[p].frequency.value(atMilliseconds: milliseconds) / sampleRate
            tone[index] += pow(10, partials[p].decibels.value(atMilliseconds: milliseconds) / 20) * sin(partials[p].phase)
        }
        let click = clickFilter.process(noise.next())
        tone[index] += design.click.amplitude * exp(-milliseconds / design.click.decayMilliseconds) * click
    }
    var filter = Biquad.highpass(cutoff: design.highpassHertz)
    return tone.map { filter.process($0) }
}

func renderThump(_ thump: Thump) -> [Double] {
    var phase = 0.0
    return (0..<Int(0.3 * sampleRate)).map { index in
        let milliseconds = Double(index) / sampleRate * 1000
        let frequency = thump.endFrequency + (thump.startFrequency - thump.endFrequency) * exp(-milliseconds / thump.glideMilliseconds)
        phase += 2 * .pi * frequency / sampleRate
        return -thump.amplitude * exp(-milliseconds / thump.decayMilliseconds) * sin(phase)
    }
}

/// A second-order section from the RBJ (Robert Bristow-Johnson) audio EQ cookbook, in transposed direct form II.
struct Biquad {
    let b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    /// Butterworth when q is 1/sqrt(2), the default.
    static func highpass(cutoff: Double, q: Double = 1 / 2.0.squareRoot()) -> Biquad {
        let omega = 2 * .pi * cutoff / sampleRate, alpha = sin(omega) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 + cos(omega)) / 2 / a0, b1: -(1 + cos(omega)) / a0, b2: (1 + cos(omega)) / 2 / a0,
                      a1: -2 * cos(omega) / a0, a2: (1 - alpha) / a0)
    }

    /// Unity gain at the centre.
    static func bandpass(centre: Double, q: Double) -> Biquad {
        let omega = 2 * .pi * centre / sampleRate, alpha = sin(omega) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(omega) / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// One impulse response per channel: noise under a two-slope energy envelope, silent before the predelay.
func renderImpulseResponses(_ reverberation: Reverberation) -> ([Double], [Double]) {
    var generator = NoiseGenerator(state: reverberation.seed)
    var left = [Double](repeating: 0, count: frameCount), right = left
    let predelay = Int(reverberation.predelayMilliseconds / 1000 * sampleRate)
    for index in predelay..<frameCount {
        let seconds = Double(index - predelay) / sampleRate
        let ramp = min(1, seconds * 1000 / reverberation.rampMilliseconds)
        let early = pow(10, -reverberation.earlyDecay * seconds / 10)
        let late = pow(10, (reverberation.lateLevel - reverberation.lateDecay * seconds) / 10)
        let amplitude = reverberation.gain * sqrt(early + late) * ramp * ramp
        let correlation = reverberation.lateCorrelation + (reverberation.earlyCorrelation - reverberation.lateCorrelation)
            * exp(-seconds * 1000 / reverberation.correlationMilliseconds)
        let shared = sqrt(correlation), own = sqrt(1 - correlation)
        let common = generator.next()
        left[index] = amplitude * (shared * common + own * generator.next())
        right[index] = amplitude * (shared * common + own * generator.next())
    }
    return (left, right)
}

/// Direct convolution. The dry tone is at most 1,675 samples long (38 ms), so this is quick without an FFT.
func convolve(_ signal: [Double], _ response: [Double]) -> [Double] {
    var output = [Double](repeating: 0, count: frameCount)
    for (offset, sample) in signal.enumerated() where sample != 0 {
        for index in 0..<(frameCount - offset) { output[offset + index] += sample * response[index] }
    }
    return output
}

/// Unchanged up to 80 % of `ceiling`, then a tanh curve that approaches `ceiling` without reaching it.
func softLimited(_ sample: Double, ceiling: Double) -> Double {
    let knee = 0.8 * ceiling, level = abs(sample)
    guard level > knee else { return sample }
    let limited = knee + (ceiling - knee) * tanh((level - knee) / (ceiling - knee))
    return sample < 0 ? -limited : limited
}

/// 24-bit PCM, because the tail falls to about -108 dBFS, below the 16-bit floor.
func writeWave(left: [Double], right: [Double], to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytesPerFrame = 6
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frameCount * bytesPerFrame))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
    append(UInt32(sampleRate)); append(UInt32(Int(sampleRate) * bytesPerFrame)); append(UInt16(bytesPerFrame)); append(UInt16(24))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(frameCount * bytesPerFrame))
    for index in 0..<frameCount {
        for sample in [left[index], right[index]] {
            let value = Int32((max(-1, min(1, sample)) * 8_388_607).rounded())
            data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16)])
        }
    }
    try data.write(to: url)
}

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Packaging/Cues")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for design in [start, stop] {
    let dry = renderDryTone(design)
    let (leftResponse, rightResponse) = renderImpulseResponses(design.reverberation)
    var left = convolve(dry, leftResponse), right = convolve(dry, rightResponse)
    // Two second-order high-pass sections at Q 0.5 each, in cascade, filter the reverb.
    for channel in [0, 1] {
        var first = Biquad.highpass(cutoff: design.wetHighpassHertz, q: 0.5), second = first
        if channel == 0 { left = left.map { second.process(first.process($0)) } } else { right = right.map { second.process(first.process($0)) } }
    }
    for (index, sample) in dry.enumerated() { left[index] += sample; right[index] += sample }
    if let thump = design.thump {
        for (index, sample) in renderThump(thump).enumerated() { left[index] += sample; right[index] += sample }
    }
    let peak = max(left.map(abs).max()!, right.map(abs).max()!)
    let ceiling = pow(10, -0.1 / 20)
    let scale = 2 * ceiling / peak
    let url = directory.appendingPathComponent("\(design.name).wav")
    try writeWave(
        left: left.map { softLimited($0 * scale, ceiling: ceiling) },
        right: right.map { softLimited($0 * scale, ceiling: ceiling) }, to: url)
    print("wrote \(url.path)")
}
