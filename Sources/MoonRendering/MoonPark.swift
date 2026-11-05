import DictationCore
import Foundation

/// A shader fold at the stopped moon's radius, level and phase. Release sends the folded shape up as smoke.
public struct MoonPark: Sendable {
    public struct Frame: Sendable {
        public let bitmap: MoonBitmap
        public let opacity: Double
        public let shader: MoonFrame
    }

    private let source: MoonBitmap
    private let sourceOpacity: Double
    private let shader: MoonFrame
    private let interruptedSource: MoonParkSource?

    @MainActor public init(source: MoonBitmap, shader: MoonFrame, opacity: Double = 1) throws {
        self.source = source
        let original = try MoonRenderer.shared.get().render(shader, pixels: source.width)
        let captured = opacity > 0 && (original.bytes != source.bytes || shader.warning > 0
            || shader.loading > 0 || shader.formation < 1 || shader.park > 0)
        interruptedSource = captured ? MoonParkSource(bitmap: source) : nil
        var initial = shader
        initial.park = 0
        initial.parkSourceWeight = 0
        initial.warning = 0
        initial.loading = 0
        initial.formation = 1
        self.shader = initial
        sourceOpacity = min(1, max(0, opacity))
    }

    @MainActor public func render(age: Double, reason: DictationMiss, departureAge: Double? = nil,
                                  reduceMotion: Bool = false) throws -> Frame {
        if reason == .secureField {
            let progress = Self.smoothstep((age - (departureAge ?? 0)) / 0.25)
            let departure = departureAge.map { 1 - Self.smoothstep($0 / 0.12) } ?? 1
            return Frame(bitmap: source, opacity: sourceOpacity * (1 - progress) * departure, shader: shader)
        }
        // Departure freezes the fold where it was; the shape on screen then rises away as smoke.
        let departureAt = departureAge.map { max(0, age - $0) }
        let entryAge = departureAt ?? age
        var animation = MoonAnimation()
        animation.showPark(at: 0, weight: Double(shader.park))
        animation.advance(to: entryAge)
        var frame = shader
        frame.park = reason.showsCopyMark ? Float(animation.park) : 0
        frame.reduceMotion = reduceMotion
        if interruptedSource != nil {
            var entry = MoonAnimation()
            entry.showPark(at: 0, weight: Double(shader.park))
            entry.advance(to: entryAge)
            frame.parkSourceWeight = Float(1 - entry.park)
        }
        let opacity = reason.showsCopyMark
            ? sourceOpacity + (1 - sourceOpacity) * Self.smoothstep(entryAge / MoonAnimation.parkEntryDuration)
            : sourceOpacity + (1 - sourceOpacity) * Self.smoothstep(entryAge / 0.25)
        let shape = entryAge <= 0 || !reason.showsCopyMark ? source
            : try MoonRenderer.shared.get().render(frame, pixels: source.width, parkSource: interruptedSource)
        if let departureAge {
            return Frame(bitmap: MoonSmoke(bitmap: shape).render(fraction: departureAge / MoonAnimation.smokeDuration),
                         opacity: opacity * MoonAnimation.smokeOpacity(after: departureAge), shader: frame)
        }
        return Frame(bitmap: shape, opacity: opacity, shader: frame)
    }

    private static func smoothstep(_ fraction: Double) -> Double {
        let progress = min(1, max(0, fraction))
        return progress * progress * (3 - 2 * progress)
    }
}
