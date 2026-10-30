// Measures one or two short cues, so that two versions of a cue can be compared on the same numbers.
//
//   swift -O Tools/MeasureCues.swift Packaging/Cues/Start.wav Packaging/Cues/Stop.wav
//
// For each file the tool prints:
//   the format, the sample peak, the RMS over the file, and the time of the envelope peak
//   the attack: the times at which the envelope first exceeds 10 % and 90 % of its peak
//   the envelope in dB against its peak, at fixed times
//   the tail: decay rate in dB/s, T60 (the time to fall by 60 dB) and the noise floor below the peak
//   the dominant partial: its frequency over time, from the peak of a short-time Fourier transform (STFT) with
//   parabolic interpolation, ignoring the 10 lowest bins
//   for each of three windows, 0-30 ms, 30-200 ms and 200-1500 ms: the spectral centroid, the -20 dB bandwidth and the
//   six strongest spectral peaks
//   the left/right correlation in the same three windows
// With exactly two files it also prints, for each window, the third-octave band levels of both and the RMS difference
// between them.

import AVFoundation
import Accelerate

struct Signal {
    var left: [Float]
    var right: [Float]
    var rate: Double
    var mono: [Float] { zip(left, right).map { ($0 + $1) / 2 } }
}

func load(_ path: String) -> Signal {
    let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(standardFormatWithSampleRate: file.fileFormat.sampleRate, channels: file.fileFormat.channelCount)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buffer)
    let count = Int(buffer.frameLength)
    let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
    let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count)) : left
    return Signal(left: left, right: right, rate: format.sampleRate)
}

func decibels(_ value: Float) -> Float { 20 * log10(max(value, 1e-9)) }

/// Magnitude spectrum of `samples[start ..< start + size]` under a Hann window. Samples outside the array count as
/// zero. `size` must be a power of two.
func spectrum(_ samples: [Float], start: Int, size: Int) -> [Float] {
    var frame = [Float](repeating: 0, count: size)
    for index in 0..<size where start + index < samples.count && start + index >= 0 { frame[index] = samples[start + index] }
    var window = [Float](repeating: 0, count: size)
    vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(size))
    let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    defer { vDSP_DFT_DestroySetup(setup) }
    var realOut = [Float](repeating: 0, count: size), imaginaryOut = [Float](repeating: 0, count: size)
    let zeros = [Float](repeating: 0, count: size)
    vDSP_DFT_Execute(setup, frame, zeros, &realOut, &imaginaryOut)
    return (0..<size / 2).map { sqrt(realOut[$0] * realOut[$0] + imaginaryOut[$0] * imaginaryOut[$0]) * 4 / Float(size) }
}

/// RMS average of the magnitude spectra of frames that start every `size / 4` samples across a time window given in
/// seconds.
func averageSpectrum(_ samples: [Float], from: Double, to: Double, rate: Double, size: Int = 4096) -> [Float] {
    var total = [Float](repeating: 0, count: size / 2), frames = 0
    var start = Int(from * rate)
    repeat {
        let magnitudes = spectrum(samples, start: start, size: size)
        for index in total.indices { total[index] += magnitudes[index] * magnitudes[index] }
        frames += 1
        start += size / 4
    } while start + size <= Int(to * rate)
    return total.map { sqrt($0 / Float(frames)) }
}

func interpolatedPeak(_ magnitudes: [Float], _ index: Int) -> Double {
    guard index > 0, index < magnitudes.count - 1 else { return Double(index) }
    let a = Double(decibels(magnitudes[index - 1])), b = Double(decibels(magnitudes[index])), c = Double(decibels(magnitudes[index + 1]))
    let denominator = a - 2 * b + c
    return Double(index) + (denominator == 0 ? 0 : 0.5 * (a - c) / denominator)
}

func peaks(_ magnitudes: [Float], rate: Double, size: Int, count: Int, floor: Float) -> [(Double, Float)] {
    var found: [(Double, Float)] = []
    for index in 2..<(magnitudes.count - 2) where magnitudes[index] > magnitudes[index - 1] && magnitudes[index] >= magnitudes[index + 1]
        && magnitudes[index] > magnitudes[index - 2] && magnitudes[index] >= magnitudes[index + 2] && decibels(magnitudes[index]) > floor {
        found.append((interpolatedPeak(magnitudes, index) * rate / Double(size), decibels(magnitudes[index])))
    }
    return Array(found.sorted { $0.1 > $1.1 }.prefix(count))
}

func centroidAndBandwidth(_ magnitudes: [Float], rate: Double, size: Int) -> (Double, Double, Double) {
    let binWidth = rate / Double(size)
    var weighted = 0.0, total = 0.0
    for (index, value) in magnitudes.enumerated() { weighted += Double(value) * Double(index) * binWidth; total += Double(value) }
    let peakIndex = magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] }!
    let threshold = magnitudes[peakIndex] * 0.1  // -20 dB
    var low = peakIndex, high = peakIndex
    while low > 0 && magnitudes[low] > threshold { low -= 1 }
    while high < magnitudes.count - 1 && magnitudes[high] > threshold { high += 1 }
    return (weighted / total, Double(low) * binWidth, Double(high) * binWidth)
}

/// RMS envelope in 1 ms frames.
func envelope(_ samples: [Float], rate: Double) -> [Float] {
    let frame = Int(rate / 1000)
    return stride(from: 0, to: samples.count - frame, by: frame).map { start in
        var value: Float = 0
        vDSP_rmsqv(Array(samples[start..<start + frame]), 1, &value, vDSP_Length(frame))
        return value
    }
}

func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
    var ab: Float = 0, aa: Float = 0, bb: Float = 0
    for (x, y) in zip(a, b) { ab += x * y; aa += x * x; bb += y * y }
    return ab / max(sqrt(aa * bb), 1e-12)
}

let windows: [(String, Double, Double)] = [("0-30 ms", 0, 0.03), ("30-200 ms", 0.03, 0.2), ("200-1500 ms", 0.2, 1.5)]

func report(_ path: String) -> Signal {
    let signal = load(path)
    let mono = signal.mono
    print("== \(path)")
    print(String(format: "format       %.0f Hz, %d frames (%.3f s)", signal.rate, mono.count, Double(mono.count) / signal.rate))
    var peak: Float = 0, rms: Float = 0
    vDSP_maxmgv(signal.left + signal.right, 1, &peak, vDSP_Length(mono.count * 2))
    vDSP_rmsqv(mono, 1, &rms, vDSP_Length(mono.count))
    let curve = envelope(mono, rate: signal.rate)
    let curvePeak = curve.max()!, peakMillisecond = curve.firstIndex(of: curvePeak)!
    let onset = curve.firstIndex { $0 > curvePeak * 0.1 }!, ninety = curve.firstIndex { $0 > curvePeak * 0.9 }!
    print(String(format: "level        sample peak %.1f dBFS, RMS over file %.1f dBFS, envelope peak at %d ms", decibels(peak), decibels(rms), peakMillisecond))
    print(String(format: "attack       10 %% at %d ms, 90 %% at %d ms (rise %d ms)", onset, ninety, ninety - onset))
    // Envelope at fixed times, each value the RMS over a window centered on the time. The window widens with time (1 ms
    // below 10 ms, 21 ms from 100 ms) so that the beating in the reverberant tail does not dominate the reading.
    func level(at millisecond: Int) -> Float {
        let half = max(0, min(10, millisecond / 10))
        let range = max(0, millisecond - half)...min(curve.count - 1, millisecond + half)
        return decibels(sqrt(range.map { curve[$0] * curve[$0] }.reduce(0, +) / Float(range.count))) - decibels(curvePeak)
    }
    let marks = [2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 150, 200, 300, 400, 500, 700, 1000, 1500, 1900]
    print("envelope dB  " + marks.map { String(format: "%d:%.0f", $0, level(at: $0)) }.joined(separator: " "))
    // Noise floor: the windowed level centered 100 ms before the end of the file. Tail decay: least squares slope of
    // the windowed envelope, sampled every 5 ms, from 80 ms until the level first comes within 10 dB of that floor. The
    // fit covers at least 80 to 120 ms, and it ends at 1000 ms if the level never comes that close.
    let floorLevel = level(at: curve.count - 100)
    let end = (80..<curve.count - 100).first { level(at: $0) < floorLevel + 10 } ?? 1000
    let tail = stride(from: 80, to: max(end, 120), by: 5).map { (Double($0), Double(level(at: $0))) }
    let meanX = tail.map(\.0).reduce(0, +) / Double(tail.count), meanY = tail.map(\.1).reduce(0, +) / Double(tail.count)
    let slope = tail.map { ($0.0 - meanX) * ($0.1 - meanY) }.reduce(0, +) / tail.map { ($0.0 - meanX) * ($0.0 - meanX) }.reduce(0, +)
    print(String(format: "tail decay   %.0f dB/s from 80 to %d ms (T60 %.2f s); floor %.0f dB below peak", slope * 1000, end, -60 / (slope * 1000), -floorLevel))
    // Dominant partial: the strongest bin above the lowest 10 in a 2048-sample window centered on each time.
    let size = 2048
    let track = [0.005, 0.01, 0.015, 0.02, 0.03, 0.05, 0.1, 0.2, 0.4, 0.8, 1.2].map { time -> String in
        let magnitudes = spectrum(mono, start: Int(time * signal.rate) - size / 2, size: size)
        let index = magnitudes.indices.dropFirst(10).max { magnitudes[$0] < magnitudes[$1] }!
        return String(format: "%.0f:%.0f", time * 1000, interpolatedPeak(magnitudes, index) * signal.rate / Double(size))
    }
    print("partial Hz   " + track.joined(separator: " "))
    for (name, from, to) in windows {
        let magnitudes = averageSpectrum(mono, from: from, to: to, rate: signal.rate, size: from == 0 ? 1024 : 8192)
        let size = from == 0 ? 1024 : 8192
        let (centroid, low, high) = centroidAndBandwidth(magnitudes, rate: signal.rate, size: size)
        let top = peaks(magnitudes, rate: signal.rate, size: size, count: 6, floor: -120).map { String(format: "%.0f Hz %.0f dB", $0.0, $0.1) }
        print(String(format: "%-12@ centroid %.0f Hz, -20 dB band %.0f-%.0f Hz; peaks: ", name, centroid, low, high) + top.joined(separator: ", "))
    }
    let correlations = [(0, 30), (30, 200), (200, 1500)].map { from, to -> String in
        let a = Int(Double(from) / 1000 * signal.rate), b = Int(Double(to) / 1000 * signal.rate)
        return String(format: "%d-%d ms %.3f", from, to, correlation(signal.left[a..<b], signal.right[a..<b]))
    }
    print("L/R corr     " + correlations.joined(separator: ", "))
    return signal
}

let paths = Array(CommandLine.arguments.dropFirst())
let signals = paths.map(report)
if signals.count == 2 {
    // Third-octave band levels (dBFS, a full-scale sine reads 0) of the two average spectra, 40 Hz to 16 kHz, and the
    // RMS difference over the bands where either file is above -100 dBFS. The difference measures the match of the
    // spectral envelope and ignores fine structure. Below -100 dBFS a compressed file holds only codec noise.
    let centres = (-14...12).map { 1000 * pow(2, Double($0) / 3) }
    for (name, from, to) in windows {
        let size = from == 0 ? 1024 : 8192
        let bands = signals.map { signal -> [Float] in
            let magnitudes = averageSpectrum(signal.mono, from: from, to: to, rate: signal.rate, size: size)
            return centres.map { centre in
                let low = Int(centre / pow(2, 1.0 / 6) * Double(size) / signal.rate), high = Int(centre * pow(2, 1.0 / 6) * Double(size) / signal.rate)
                return 10 * log10(max((low...max(low, high)).map { magnitudes[$0] * magnitudes[$0] }.reduce(0, +), 1e-20))
            }
        }
        let compared = centres.indices.filter { max(bands[0][$0], bands[1][$0]) > -100 }
        let distance = sqrt(compared.map { pow(bands[0][$0] - bands[1][$0], 2) }.reduce(0, +) / Float(compared.count))
        print(String(format: "bands %@, RMS difference %.1f dB over %d bands", name, distance, compared.count))
        print("  Hz        " + centres.map { String(format: "%6.0f", $0) }.joined())
        print("  first     " + bands[0].map { String(format: "%6.0f", $0) }.joined())
        print("  second    " + bands[1].map { String(format: "%6.0f", $0) }.joined())
    }
}
