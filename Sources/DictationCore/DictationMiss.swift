import Foundation

public enum DictationMiss: String, CaseIterable, Sendable, Codable {
    case focusMoved
    case noTextField
    case unconfirmed
    case clipboardChanged
    case secureField
    case modelUnavailable
    case microphoneDisconnected

    public var holdDuration: Double {
        switch self {
        case .secureField: 1.05
        case .clipboardChanged: 2.2
        default: 1.7
        }
    }

    public func announcement(pasteShortcut: String?) -> String {
        switch self {
        case .focusMoved: return "Copied. Focus moved before it was typed. Press Command V to paste."
        case .noTextField: return "Copied. Nothing had a text cursor. Press Command V to paste."
        case .unconfirmed: return "Copied. The text may already be inserted. Check before pressing Command V to paste."
        case .clipboardChanged:
            let recovery = pasteShortcut.map { " Press \($0) to paste the last text." } ?? " Choose Paste last text from the menu."
            return "Your clipboard is newer, so the dictation was not copied." + recovery
        case .secureField: return "That is a password field. Nothing was typed, copied, or kept."
        case .modelUnavailable: return "The speech model recovered. Your dictation is copied. Press Command V to paste."
        case .microphoneDisconnected: return "The microphone disconnected. What it heard is copied. Press Command V to paste."
        }
    }
}

/// Timing for the parked moon. Transcription completion, hovering, and explicit paste are separate events.
public struct MoonParkAnimation: Sendable {
    public static let arrivalDuration = 0.5
    public enum Departure: Sendable { case timeout, pasted }
    public let reason: DictationMiss
    public private(set) var beganAt: Double
    public private(set) var departure: Departure?
    public private(set) var departedAt: Double?
    private var hoverBeganAt: Double?
    private var heldDuration = 0.0

    public init(reason: DictationMiss, at time: Double) { self.reason = reason; beganAt = time }

    public func age(at time: Double) -> Double { max(0, time - beganAt) }
    public func departureAge(at time: Double) -> Double? { departedAt.map { max(0, time - $0) } }

    public mutating func setHovered(_ hovered: Bool, at time: Double) {
        if hovered && hoverBeganAt == nil { hoverBeganAt = time }
        if !hovered, let hoverBeganAt { heldDuration += time - hoverBeganAt; self.hoverBeganAt = nil }
    }

    public mutating func leave(_ departure: Departure, at time: Double) {
        guard departedAt == nil else { return }
        self.departure = departure
        departedAt = time
    }

    public mutating func advance(to time: Double) {
        guard departedAt == nil, hoverBeganAt == nil else { return }
        let deadline = beganAt + 0.52 + reason.holdDuration + heldDuration
        if time >= deadline { leave(.timeout, at: deadline) }
    }

    public func isFinished(at time: Double, reduceMotion: Bool) -> Bool {
        guard let age = departureAge(at: time) else { return false }
        return age > (reduceMotion ? 0.15 : 0.52)
    }
}
