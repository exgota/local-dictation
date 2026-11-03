import Foundation

/// Captures only the lit pixels. Particle hashes use double precision, matching the canvas implementation.
public struct MoonSmoke: Sendable {
    private let pixels: Int
    private let particles: [MoonParticle]

    public init(bitmap: MoonBitmap) {
        pixels = bitmap.width
        particles = MoonParticle.capture(bitmap)
    }

    public func render(fraction: Double) -> MoonBitmap {
        let half = Double(pixels) / 2
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        for particle in particles {
            let age = (fraction - particle.delay * 0.25) / 0.75
            if age > 0.45 + 0.55 * particle.lifetime { continue }
            let height = age <= 0 ? 0 : age * age * (0.4 + 0.7 * particle.rise)
            let horizontal = particle.horizontal + sin(height * 7 + particle.curl * 6.3) * height * 0.28
            let vertical = particle.vertical + height
            // JavaScript Math.round rounds ties toward positive infinity, including negative coordinates.
            let column = Int(floor(half + horizontal * half - 0.5 + 0.5))
            let row = Int(floor(half - vertical * half - 0.5 + 0.5))
            guard column >= 0, row >= 0, column < pixels, row < pixels,
                  pow(Double(column) + 0.5 - half, 2) + pow(Double(row) + 0.5 - half, 2) <= half * half else { continue }
            let offset = (row * pixels + column) * 4
            bytes[offset] = 245
            bytes[offset + 1] = 245
            bytes[offset + 2] = 242
            bytes[offset + 3] = 255
        }
        return MoonBitmap(width: pixels, height: pixels, bytes: bytes)
    }
}
