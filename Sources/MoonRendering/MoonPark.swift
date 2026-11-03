import DictationCore
import Foundation

/// The Park motion uses the stopped moon's particles, preserving their smoke positions and velocities on arrival.
public struct MoonPark: Sendable {
    private struct Launch: Sendable {
        let horizontal, vertical, horizontalVelocity, verticalVelocity: Double
        let returned: Bool
        let particle: MoonParticle
    }
    private struct Pair: Sendable {
        let source: Launch
        let target: MoonParticle
        let satellite: Bool
        let duration, delay: Double
    }
    public struct Frame: Sendable {
        public let bitmap: MoonBitmap
        public let opacity: Double
    }

    private let pixels: Int
    private let main: [MoonParticle]
    private let satellite: [MoonParticle]
    private let pairs: [Pair]
    private let centerHorizontal, centerVertical, satelliteHorizontal, satelliteVertical: Double

    public init(source: MoonBitmap, main: MoonBitmap, satellite: MoonBitmap, smokeFraction: Double) {
        pixels = source.width
        let half = Double(pixels) / 2
        let offset = floor(0.12 * half + 0.5) / half
        centerHorizontal = -offset
        centerVertical = -offset
        satelliteHorizontal = floor(0.44 * half + 0.5) / half
        satelliteVertical = floor(0.46 * half + 0.5) / half
        self.main = MoonParticle.capture(main).map {
            var particle = $0
            particle.horizontal -= offset
            particle.vertical -= offset
            return particle
        }
        let scale = Double(satellite.width) / Double(pixels)
        let horizontal = satelliteHorizontal, vertical = satelliteVertical
        self.satellite = MoonParticle.capture(satellite).map {
            var particle = $0
            particle.horizontal = particle.horizontal * scale + horizontal
            particle.vertical = particle.vertical * scale + vertical
            return particle
        }
        let launched = MoonParticle.capture(source).map { Self.launch($0, fraction: smokeFraction) }.sorted { $0.vertical > $1.vertical }
        let cut = Int(floor(Double(launched.count) * 0.2 + 0.5))
        pairs = Self.pair(Array(launched.dropFirst(cut)), self.main, satellite: false)
            + Self.pair(Array(launched.prefix(cut)), self.satellite, satellite: true)
    }

    public static func satellitePixels(for pixels: Int) -> Int { max(2, Int(floor(Double(pixels) / 6 + 0.5)) * 2) }

    private static func launch(_ particle: MoonParticle, fraction: Double) -> Launch {
        let age = (fraction - particle.delay * 0.25) / 0.75
        if age <= 0 {
            return Launch(horizontal: particle.horizontal, vertical: particle.vertical, horizontalVelocity: 0, verticalVelocity: 0,
                          returned: false, particle: particle)
        }
        let coefficient = 0.4 + 0.7 * particle.rise
        let height = age * age * coefficient
        let velocity = 2 * age * coefficient / (0.75 * 450) * 1000
        let phase = height * 7 + particle.curl * 6.3
        let horizontal = particle.horizontal + sin(phase) * height * 0.28
        if age > 0.45 + 0.55 * particle.lifetime {
            return Launch(horizontal: horizontal, vertical: 1.04 + 0.4 * particle.lifetime,
                          horizontalVelocity: 0, verticalVelocity: 0, returned: true, particle: particle)
        }
        return Launch(horizontal: horizontal, vertical: particle.vertical + height,
                      horizontalVelocity: (cos(phase) * 7 * height * 0.28 + sin(phase) * 0.28) * velocity,
                      verticalVelocity: velocity, returned: false, particle: particle)
    }

    private static func pair(_ sources: [Launch], _ targets: [MoonParticle], satellite: Bool) -> [Pair] {
        guard !sources.isEmpty, !targets.isEmpty else { return [] }
        let sources = sources.sorted { $0.horizontal == $1.horizontal ? $0.vertical > $1.vertical : $0.horizontal < $1.horizontal }
        let targets = targets.sorted { $0.horizontal == $1.horizontal ? $0.vertical > $1.vertical : $0.horizontal < $1.horizontal }
        let count = max(sources.count, targets.count)
        return (0..<count).map { index in
            let source = sources[index * sources.count / count]
            return Pair(source: source, target: targets[index * targets.count / count], satellite: satellite,
                        duration: (source.returned ? 0.3 : 0.28) + 0.16 * source.particle.rise,
                        delay: source.returned ? 0.07 * source.particle.lifetime : 0)
        }
    }

    public func render(age: Double, reason: DictationMiss, departure: MoonParkAnimation.Departure? = nil,
                       departureAge: Double? = nil, reduceMotion: Bool = false) -> Frame {
        let half = Double(pixels) / 2
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        func put(_ horizontal: Double, _ vertical: Double) {
            let column = Int(floor(half + horizontal * half))
            let row = Int(floor(half - vertical * half))
            guard column >= 0, row >= 0, column < pixels, row < pixels,
                  pow(Double(column) + 0.5 - half, 2) + pow(Double(row) + 0.5 - half, 2) <= half * half else { return }
            let offset = (row * pixels + column) * 4
            bytes[offset] = 245; bytes[offset + 1] = 245; bytes[offset + 2] = 242; bytes[offset + 3] = 255
        }
        func drawMain(threshold: Double, horizontal: Double) {
            for particle in main where particle.lifetime >= threshold { put(particle.horizontal + horizontal, particle.vertical) }
        }
        func drawSatellite(after seconds: Double, motion: SatelliteMotion) {
            let offset: (Double, Double, Bool)
            switch motion {
            case .swallow:
                let progress = pow(Self.clamp(seconds / 0.32), 3)
                offset = ((centerHorizontal - satelliteHorizontal) * progress, (centerVertical - satelliteVertical) * progress, true)
            case .launch: offset = (0, 0.35 * seconds + 0.5 * 16 * seconds * seconds, false)
            case .float: offset = (0, 0.022 * sin(seconds / 1.6 * 6.283), false)
            case .stationary: offset = (0, 0, false)
            }
            for particle in satellite {
                let horizontal = particle.horizontal + offset.0, vertical = particle.vertical + offset.1
                if offset.2 && pow(horizontal - centerHorizontal, 2) + pow(vertical - centerVertical, 2) < 0.42 * 0.42 { continue }
                put(horizontal, vertical)
            }
        }
        let shakeAge = age - 1.06
        let shake = reason == .secureField && !reduceMotion && shakeAge >= 0 ? MoonAnimation.refusalShake(after: shakeAge) : 0
        var opacity = 1.0
        if reduceMotion {
            drawMain(threshold: -1, horizontal: 0)
            if reason != .secureField || age < 0.7 { drawSatellite(after: 0, motion: .stationary) }
            opacity = departureAge.map { 1 - Self.clamp($0 / 0.15) } ?? Self.clamp(age / 0.15)
        } else if let departureAge {
            let pasted = departure == .pasted && reason != .secureField
            drawMain(threshold: Self.clamp((departureAge - (pasted ? 0.14 : 0.3)) / 0.26), horizontal: shake)
            if reason != .secureField { drawSatellite(after: departureAge, motion: pasted ? .launch : .swallow) }
            opacity = 1 - Self.clamp((departureAge - (pasted ? 0.38 : 0.54)) / 0.15)
            if departureAge > 0.52 { opacity = 0 }
        } else if age < MoonParkAnimation.arrivalDuration {
            for pair in pairs {
                let progress = Self.clamp((age - pair.delay) / pair.duration)
                let velocityScale = 0.7 * pair.duration
                put(Self.hermite(pair.source.horizontal, pair.target.horizontal, pair.source.horizontalVelocity * velocityScale, progress)
                    + (pair.satellite ? 0 : shake),
                    Self.hermite(pair.source.vertical, pair.target.vertical, pair.source.verticalVelocity * velocityScale, progress))
            }
        } else {
            drawMain(threshold: -1, horizontal: shake)
            let restingAge = age - MoonParkAnimation.arrivalDuration
            if reason == .secureField {
                drawSatellite(after: restingAge - 0.2, motion: restingAge < 0.2 ? .float : .swallow)
            } else { drawSatellite(after: restingAge, motion: .float) }
        }
        return Frame(bitmap: MoonBitmap(width: pixels, height: pixels, bytes: bytes), opacity: opacity)
    }

    private enum SatelliteMotion { case float, swallow, launch, stationary }
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func hermite(_ start: Double, _ end: Double, _ velocity: Double, _ progress: Double) -> Double {
        let square = progress * progress, cube = square * progress
        return start * (2 * cube - 3 * square + 1) + velocity * (cube - 2 * square + progress) + end * (3 * square - 2 * cube)
    }
}
