// Posts synthetic keyboard events for shortcut verification.
// Usage: post_keyboard_events COMMAND, where COMMAND is one of
//   fn-tap | fn-hold SECONDS | fn-down | fn-up | fn-chord
//   option-tap | option-down | option-up | option-chord | option-a
//   right-option-down | right-option-up | escape
// fn-chord sends Left Arrow and option-chord sends A while the modifier is down. option-a sends A with Option flagged,
// for use between option-down and option-up.
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
func flags(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)!
    event.type = .flagsChanged
    event.flags = flags
    event.post(tap: .cghidEventTap)
}
let keySource = CGEventSource(stateID: .privateState)
func key(_ keyCode: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
    let event = CGEvent(keyboardEventSource: keySource, virtualKey: keyCode, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
}
let fnFlags = CGEventFlags(rawValue: CGEventFlags.maskSecondaryFn.rawValue | 0x100)
let optionFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20 | 0x100)
let arguments = CommandLine.arguments
switch arguments[1] {
case "fn-down": flags(63, fnFlags)
case "fn-up": flags(63, CGEventFlags(rawValue: 0x100))
case "fn-tap": flags(63, fnFlags); usleep(80_000); flags(63, CGEventFlags(rawValue: 0x100))
case "fn-hold": flags(63, fnFlags); usleep(useconds_t(Double(arguments[2])! * 1_000_000)); flags(63, CGEventFlags(rawValue: 0x100))
case "option-tap": flags(58, optionFlags); usleep(80_000); flags(58, CGEventFlags(rawValue: 0x100))
case "option-chord": flags(58, optionFlags); usleep(50_000); key(0, true, optionFlags); key(0, false, optionFlags); usleep(50_000); flags(58, CGEventFlags(rawValue: 0x100))
case "option-a": key(0, true, optionFlags); key(0, false, optionFlags)
case "right-option-down": flags(61, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40 | 0x100))
case "right-option-up": flags(61, CGEventFlags(rawValue: 0x100))
case "option-down": flags(58, optionFlags)
case "option-up": flags(58, CGEventFlags(rawValue: 0x100))
case "fn-chord": flags(63, fnFlags); usleep(50_000); key(123, true, fnFlags); key(123, false, fnFlags); usleep(50_000); flags(63, CGEventFlags(rawValue: 0x100))
case "escape":
    // On this Mac, an Escape from the private-state source is dropped before it reaches the event taps. An Escape from
    // the HID-state source, with a realistic gap (30 ms) between key-down and key-up, is delivered like a physical key.
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)!.post(tap: .cghidEventTap)
        usleep(30_000)
    }
default: print("unknown command")
}
