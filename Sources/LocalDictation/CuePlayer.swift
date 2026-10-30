import AVFoundation

/// Start and stop sounds. Each cue is the bundled sound that `Tools/GenerateCues.swift` synthesises, or a short macOS
/// system sound when the bundled file does not load.
@MainActor final class CuePlayer {
    private let startPlayer = player(bundledName: "Start", fallbackPath: "/System/Library/Sounds/Pop.aiff")
    private let stopPlayer = player(bundledName: "Stop", fallbackPath: "/System/Library/Sounds/Bottle.aiff")

    /// Volume is a linear gain from 0 to 1. At 0 no sound plays.
    func playStart(volume: Double) { play(startPlayer, volume: volume) }
    func playStop(volume: Double) { play(stopPlayer, volume: volume) }

    private func play(_ player: AVAudioPlayer?, volume: Double) {
        guard let player, volume > 0 else { return }
        player.volume = Float(min(max(volume, 0), 1))
        player.currentTime = 0
        player.play()
    }

    private static func player(bundledName: String, fallbackPath: String) -> AVAudioPlayer? {
        let bundled = Bundle.main.url(forResource: bundledName, withExtension: "wav", subdirectory: "Cues")
        for url in [bundled, URL(fileURLWithPath: fallbackPath)].compactMap({ $0 }) {
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                return player
            }
        }
        return nil
    }
}
