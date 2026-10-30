import Foundation

/// Virtual key codes from Carbon's Events.h. They are repeated here so that this module does not depend on Carbon.
public enum VirtualKey {
    public static let function: UInt16 = 63
    public static let option: UInt16 = 58
    public static let rightOption: UInt16 = 61
    public static let command: UInt16 = 55
    public static let rightCommand: UInt16 = 54
    public static let control: UInt16 = 59
    public static let rightControl: UInt16 = 62
    public static let shift: UInt16 = 56
    public static let rightShift: UInt16 = 60
    public static let capsLock: UInt16 = 57
    public static let escape: UInt16 = 53
    public static let letterV: UInt16 = 9
    public static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]

    public static let modifierKeys: Set<UInt16> = [
        function, option, rightOption, command, rightCommand, control, rightControl, shift, rightShift, capsLock,
    ]
}

/// Raw `CGEventFlags` bits, including the device-specific bits from IOLLEvent.h that tell left and right keys apart.
public enum EventFlagBits {
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let secondaryFunction: UInt64 = 0x0080_0000
    static let deviceLeftControl: UInt64 = 0x0000_0001
    static let deviceLeftShift: UInt64 = 0x0000_0002
    static let deviceRightShift: UInt64 = 0x0000_0004
    static let deviceLeftCommand: UInt64 = 0x0000_0008
    static let deviceRightCommand: UInt64 = 0x0000_0010
    static let deviceLeftOption: UInt64 = 0x0000_0020
    static let deviceRightOption: UInt64 = 0x0000_0040
    static let deviceRightControl: UInt64 = 0x0000_2000

    /// Whether the modifier key `keyCode` is down according to `flags`. Returns nil when `keyCode` is not one of the
    /// nine modifier keys it reads: Fn, and the left and right Option, Control, Shift and Command keys. Caps Lock
    /// returns nil.
    public static func isModifierDown(keyCode: UInt16, flags: UInt64) -> Bool? {
        switch keyCode {
        case VirtualKey.function: return flags & secondaryFunction != 0
        case VirtualKey.option: return flags & deviceLeftOption != 0
        case VirtualKey.rightOption: return flags & deviceRightOption != 0
        case VirtualKey.control: return flags & deviceLeftControl != 0
        case VirtualKey.rightControl: return flags & deviceRightControl != 0
        case VirtualKey.shift: return flags & deviceLeftShift != 0
        case VirtualKey.rightShift: return flags & deviceRightShift != 0
        case VirtualKey.command: return flags & deviceLeftCommand != 0
        case VirtualKey.rightCommand: return flags & deviceRightCommand != 0
        default: return nil
        }
    }
}

/// The modifiers that distinguish keyboard shortcuts. Fn is excluded: macOS sets it on function-row and arrow keys.
public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    public init(eventFlags flags: UInt64) {
        var set: ModifierSet = []
        if flags & EventFlagBits.control != 0 { set.insert(.control) }
        if flags & EventFlagBits.option != 0 { set.insert(.option) }
        if flags & EventFlagBits.shift != 0 { set.insert(.shift) }
        if flags & EventFlagBits.command != 0 { set.insert(.command) }
        self = set
    }

    /// Symbols in the standard macOS order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "")
            + (contains(.command) ? "⌘" : "")
    }
}

/// A key with an exact set of modifiers.
public struct KeyChord: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCode == self.keyCode && ModifierSet(eventFlags: flags) == modifiers
    }

    /// Re-paste the last transcript: ⌥⇧V.
    public static let defaultRepaste = KeyChord(keyCode: VirtualKey.letterV, modifiers: [.option, .shift])

    /// Packs into the low 32 bits of a `UInt64` for lock-free sharing with the event tap thread. Bit 31 is always set,
    /// so zero means no chord.
    var packed: UInt64 { 1 << 31 | UInt64(modifiers.rawValue) << 16 | UInt64(keyCode) }

    init?(packed: UInt64) {
        guard packed & (1 << 31) != 0 else { return nil }
        self.init(keyCode: UInt16(packed & 0xFFFF), modifiers: ModifierSet(rawValue: UInt8((packed >> 16) & 0xFF)))
    }
}

/// The key that starts and stops dictation.
public enum TriggerKey: Codable, Hashable, Sendable {
    case function
    case rightOption
    case rightCommand
    /// Any non-modifier key, typically an F-key, with an exact modifier set.
    case key(KeyChord)

    /// The virtual key code of the physical modifier key, for modifier-only triggers. Nil for `.key`.
    public var modifierKeyCode: UInt16? {
        switch self {
        case .function: return VirtualKey.function
        case .rightOption: return VirtualKey.rightOption
        case .rightCommand: return VirtualKey.rightCommand
        case .key: return nil
        }
    }

    public var chord: KeyChord? {
        if case .key(let chord) = self { return chord }
        return nil
    }
}

/// How the trigger key controls recording.
public enum TriggerMode: String, Codable, CaseIterable, Sendable {
    /// Each clean press and release of the trigger starts or stops recording. The action happens on release.
    case toggle
    /// Record while the key is held.
    case hold
    /// Record while the key is held. A quick double tap locks recording on until the next clean press and release.
    case doubleTapLock
}
