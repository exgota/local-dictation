import Foundation

public struct MoonEntranceFrame: Sendable {
    public let formation: Double
    public let opacity: Double
}

public enum MoonEntranceAnimation {
    public static func frame(after elapsed: Double) -> MoonEntranceFrame {
        let age = max(0, elapsed)
        return MoonEntranceFrame(formation: min(1, 0.72 + 0.28 * age / 0.15),
                                 opacity: opacity(after: age, duration: 0.15))
    }

    /// The existing cubic (0.16, 1, 0.3, 1), evaluated without changing the shipped frame values.
    private static func opacity(after age: Double, duration: Double) -> Double {
        let progress = min(1, age / duration)
        func coordinate(_ fraction: Double, _ first: Double, _ second: Double) -> Double {
            let complement = 1 - fraction
            return 3 * complement * complement * fraction * first + 3 * complement * fraction * fraction * second + fraction * fraction * fraction
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<20 {
            let middle = (lower + upper) / 2
            if coordinate(middle, 0.16, 0.3) < progress { lower = middle } else { upper = middle }
        }
        return coordinate((lower + upper) / 2, 1, 1)
    }
}
