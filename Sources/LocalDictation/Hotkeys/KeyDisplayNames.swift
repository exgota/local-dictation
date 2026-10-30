import Carbon.HIToolbox
import DictationCore

extension TriggerKey {
    static let modifierChoices: [TriggerKey] = [.function, .rightOption, .rightCommand]

    var displayName: String {
        switch self {
        case .function: return "Fn"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .key(let chord): return chord.displayName
        }
    }
}

extension TriggerMode {
    var displayName: String {
        switch self {
        case .toggle: return "Toggle"
        case .hold: return "Hold to talk"
        case .doubleTapLock: return "Hold, double-tap to lock"
        }
    }
}

extension KeyChord {
    var displayName: String { modifiers.symbols + KeyDisplayNames.name(of: keyCode) }
}

enum KeyDisplayNames {
    static func name(of keyCode: UInt16) -> String {
        if let name = VirtualKey.functionKeys[keyCode] { return name }
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Escape", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up",
            kVK_PageDown: "Page Down",
        ]
        if let name = named[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length,
                &characters)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
