import Foundation

/// A frozen interrupted stop frame, expressed as a signed distance and tone for the same shader morph.
/// Ordinary moons use their analytic circle directly; this is only needed after dots have dispersed.
public struct MoonParkSource: Sendable {
    let pixels: Int
    let values: [Float]

    init(bitmap: MoonBitmap) {
        let pixels = bitmap.width
        self.pixels = pixels
        let occupied = stride(from: 3, to: bitmap.bytes.count, by: 4).map { bitmap.bytes[$0] > 0 }
        func distances(to inside: Bool) -> [Float] {
            var result = occupied.map { $0 == inside ? Float(0) : Float(pixels * 2) }
            let diagonal = Float(2).squareRoot()
            for row in 0..<pixels {
                for column in 0..<pixels {
                    let index = row * pixels + column
                    if column > 0 { result[index] = min(result[index], result[index - 1] + 1) }
                    if row > 0 {
                        result[index] = min(result[index], result[index - pixels] + 1)
                        if column > 0 { result[index] = min(result[index], result[index - pixels - 1] + diagonal) }
                        if column + 1 < pixels { result[index] = min(result[index], result[index - pixels + 1] + diagonal) }
                    }
                }
            }
            for row in (0..<pixels).reversed() {
                for column in (0..<pixels).reversed() {
                    let index = row * pixels + column
                    if column + 1 < pixels { result[index] = min(result[index], result[index + 1] + 1) }
                    if row + 1 < pixels {
                        result[index] = min(result[index], result[index + pixels] + 1)
                        if column > 0 { result[index] = min(result[index], result[index + pixels - 1] + diagonal) }
                        if column + 1 < pixels { result[index] = min(result[index], result[index + pixels + 1] + diagonal) }
                    }
                }
            }
            return result
        }
        let interior = distances(to: false), exterior = distances(to: true)
        var samples = [Float]()
        samples.reserveCapacity(pixels * pixels * 2)
        for index in occupied.indices {
            let distance = occupied[index] ? 0.5 - interior[index] : exterior[index] - 0.5
            samples.append(distance * 2 / Float(pixels))
            samples.append(occupied[index] ? 1 : 0)
        }
        values = samples
    }
}
