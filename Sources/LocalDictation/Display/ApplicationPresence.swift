import AppKit

/// Local Dictation lives in the menu bar. While one of its windows is open it behaves like an ordinary app, with a
/// Dock icon, a place in Command-Tab and a main menu, and it returns to the menu bar when the last window closes.
@MainActor final class ApplicationPresence {
    static let shared = ApplicationPresence()
    private var windows: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Brings the window in front of every other app's windows, including System Settings after a permission switch.
    func bringToFront(_ window: NSWindow) {
        track(window)
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Self.activate()
        // An app that has just become a regular app is often refused activation in the same turn of the run loop.
        for delay in [0.05, 0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window, window.isVisible, !NSApp.isActive || !window.isKeyWindow else { return }
                Self.activate()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
        // Still refused, as when another app's password field holds secure input: ask Launch Services to open this
        // app, which activates it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak window] in
            guard let window, window.isVisible, !NSApp.isActive else { return }
            Self.reopenToFront()
        }
    }

    /// True while the app opens itself to take the front, so the reopen event does not open another window.
    private(set) static var reopeningItself = false

    private static func reopenToFront() {
        reopeningItself = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { reopeningItself = false } }
        }
    }

    /// `NSApp.activate()` is only a request: macOS 27 refuses it while System Settings or Finder is active, which left
    /// setup and the Move alert behind them. Activating as if the frontmost app had yielded is honored.
    static func activate() {
        let current = NSRunningApplication.current
        // While the status menu is open, or just after it closes, macOS can report this app as frontmost although
        // another app is still active, so the active app is looked up as well.
        let workspace = NSWorkspace.shared
        let candidates = [workspace.frontmostApplication, workspace.menuBarOwningApplication]
            + workspace.runningApplications.filter(\.isActive).map { Optional($0) }
        if let front = candidates.compactMap({ $0 }).first(where: { $0 != current }) {
            // macOS refuses this while another app holds secure input (a focused password field); the window is
            // still ordered in front, and a click makes it key.
            current.activate(from: front, options: [])
        }
        NSApp.activate()
    }

    /// Ends the launch as a menu bar app unless a window is open. The Move alert leaves the app regular, and switching
    /// to accessory and straight back while active leaves the menu bar unresponsive.
    func returnToMenuBarWithoutWindows() {
        if windows.isEmpty, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    /// The main menu supplies the standard key equivalents (Copy, Paste, Close, Quit) to every window.
    static func installMainMenu(showSettings: Selector, target: AnyObject) {
        let main = NSMenu()
        let application = NSMenu(title: "Local Dictation")
        let settings = NSMenuItem(title: "Settings…", action: showSettings, keyEquivalent: ",")
        settings.target = target
        application.addItem(settings)
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Local Dictation", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = application.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: application, title: "Local Dictation")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    private func track(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if windows[key] == nil {
            windows[key] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.forget(key) }
            }
        }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    private func forget(_ key: ObjectIdentifier) {
        if let observer = windows.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
