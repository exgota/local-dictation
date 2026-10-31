import Foundation

public enum AudioRecorderError: LocalizedError {
    case inputUnavailable
    case selectedDeviceUnavailable
    case converterUnavailable

    public var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "No microphone input is available."
        case .selectedDeviceUnavailable: return "The selected microphone is not available. Choose another in Settings."
        case .converterUnavailable: return "The microphone format cannot be converted to 16 kHz."
        }
    }

    public var showsMicrophoneWarning: Bool {
        switch self {
        case .inputUnavailable, .selectedDeviceUnavailable: return true
        case .converterUnavailable: return false
        }
    }
}
