import Foundation

struct MoonParticle: Sendable {
    var horizontal, vertical: Double
    let delay, rise, curl, lifetime: Double

    static func capture(_ bitmap: MoonBitmap) -> [Self] {
        let pixels = bitmap.width
        let half = Double(pixels) / 2
        var captured: [Self] = []
        for row in 0..<pixels {
            for column in 0..<pixels where bitmap.bytes[(row * pixels + column) * 4 + 3] > 0 {
                func hash(_ index: Double) -> Double {
                    let value = sin(Double(column) * 127.1 + Double(row) * 311.7 + index * 74.7) * 43758.5453
                    return value - floor(value)
                }
                captured.append(Self(horizontal: (Double(column) + 0.5 - half) / half,
                                     vertical: (half - Double(row) - 0.5) / half,
                                     delay: hash(1), rise: hash(2), curl: hash(3), lifetime: hash(4)))
            }
        }
        return captured
    }
}
