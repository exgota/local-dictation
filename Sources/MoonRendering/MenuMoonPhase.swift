import Foundation

/// The menu coin uses one-pixel ordered dither in a fixed 60 × 60 bitmap, displayed at 30 pt.
public enum MenuMoonPhase: CaseIterable, Sendable {
    case full, active, crescent, newMoon

    public func bitmap() -> MoonBitmap {
        let diameter: Double = self == .active ? 42 : 40
        let light: (Double, Double, Double)
        let ambient: Double
        switch self {
        case .full, .active: light = (-0.35, 0.45, 0.82); ambient = 0
        case .crescent: light = (-1, 0.15, 0.05); ambient = 0.06
        case .newMoon: light = (0, 0, -1); ambient = 0.16
        }
        let halo: Double = self == .active ? 0.14 : 0
        let size = 60
        let bayer: [[Double]] = [
            [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
            [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
            [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
            [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21],
        ]
        let length = sqrt(light.0 * light.0 + light.1 * light.1 + light.2 * light.2)
        let sun = (light.0 / length, light.1 / length, light.2 / length)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let radius = diameter / 2, center = Double(size) / 2
        for row in 0..<size {
            for column in 0..<size {
                let x = (Double(column) + 0.5 - center) / radius
                let y = (center - Double(row) - 0.5) / radius
                let distance = x * x + y * y
                var tone = 0.0
                if distance <= 1 {
                    let z = sqrt(1 - distance)
                    let lambert = max(0, x * sun.0 + y * sun.1 + z * sun.2)
                    tone = min(1, pow(lambert, 0.75) * 1.05 + ambient * (0.6 + 0.4 * z))
                } else if halo > 0 {
                    let ring = sqrt(distance)
                    if ring < 1.2 { tone = halo * (1.2 - ring) / 0.2 }
                }
                let threshold = (bayer[row % 8][column % 8] + 0.5) / 64
                if tone > threshold {
                    let index = (row * size + column) * 4
                    pixels[index] = 242; pixels[index + 1] = 242
                    pixels[index + 2] = 239; pixels[index + 3] = 255
                }
            }
        }
        return MoonBitmap(width: size, height: size, bytes: pixels)
    }
}
