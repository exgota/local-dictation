import AppKit
import Carbon.HIToolbox
import DictationCore

@MainActor enum StatusMenu {
    struct State {
        var recording = false
        var pasteChord: KeyChord? = .defaultRepaste
        var pauseChord: KeyChord?
        var canPaste = false
        var keepsHistory = false
        var paused = false
        var opensAtLogin = false
        var hasPendingUpdate = false
    }

    static func populate(_ menu: NSMenu, state: State, target: AnyObject?) {
        menu.removeAllItems()
        menu.minimumWidth = 252
        menu.autoenablesItems = false
        menu.addItem(item(state.recording ? "Stop dictation" : "Start dictation", #selector(ApplicationDelegate.toggleDictation)))
        let paste = item("Paste last text", #selector(ApplicationDelegate.repasteLastTranscript))
        setShortcut(state.pasteChord, on: paste)
        paste.isEnabled = state.canPaste
        menu.addItem(paste)
        if state.keepsHistory { menu.addItem(item("Show history", #selector(ApplicationDelegate.showHistory))) }
        let pause = item(state.paused ? "Resume all shortcuts" : "Pause all shortcuts", #selector(ApplicationDelegate.togglePause))
        setShortcut(state.pauseChord, on: pause)
        menu.addItem(pause)
        menu.addItem(.separator())
        if state.hasPendingUpdate { menu.addItem(item("Install update…", #selector(ApplicationDelegate.checkForUpdates))) }
        let login = item("Open at login", #selector(ApplicationDelegate.toggleOpenAtLogin))
        login.state = state.opensAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(ApplicationDelegate.showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil {
            item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : target
        }
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    private static func setShortcut(_ chord: KeyChord?, on item: NSMenuItem) {
        guard let chord, let equivalent = keyEquivalent(for: chord.keyCode),
              chord.modifiers.subtracting([.control, .option, .shift, .command]).isEmpty else { return }
        item.keyEquivalent = equivalent
        var modifiers: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.control) { modifiers.insert(.control) }
        if chord.modifiers.contains(.option) { modifiers.insert(.option) }
        if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if chord.modifiers.contains(.command) { modifiers.insert(.command) }
        item.keyEquivalentModifierMask = modifiers
    }

    private static func keyEquivalent(for keyCode: UInt16) -> String? {
        guard !VirtualKey.modifierKeys.contains(keyCode) else { return nil }
        let special: [Int: Int] = [
            kVK_Space: 0x20, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Delete: 0x08, kVK_Escape: 0x1B,
            kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
            kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
            kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
            kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        ]
        if let scalar = special[Int(keyCode)].flatMap(UnicodeScalar.init) { return String(scalar) }
        if let name = VirtualKey.functionKeys[keyCode], let number = Int(name.dropFirst()),
           let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) { return String(scalar) }
        let name = KeyDisplayNames.name(of: keyCode).lowercased()
        return name.unicodeScalars.count == 1 && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? name : nil
    }
}
