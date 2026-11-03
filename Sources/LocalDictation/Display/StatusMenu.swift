import AppKit
import DictationCore
import MoonRendering

@MainActor enum StatusMenu {
    enum HeaderState: CaseIterable {
        case ready, listening, transcribing, loading, paused, blocked

        var title: String {
            switch self {
            case .ready: "Ready"
            case .listening: "Listening"
            case .transcribing: "Transcribing"
            case .loading: "Loading speech model"
            case .paused: "Shortcuts paused"
            case .blocked: "Shortcuts blocked"
            }
        }

        var moonPhase: MenuMoonPhase {
            switch self {
            case .ready: .full
            case .listening, .transcribing: .active
            case .loading: .crescent
            case .paused, .blocked: .newMoon
            }
        }
    }

    struct State {
        var header: HeaderState = .ready
        var detail = ""
        var recording = false
        var trigger: TriggerKey = .function
        var pasteChord: KeyChord? = .defaultRepaste
        var canPaste = false
        var keepsHistory = false
        var paused = false
        var opensAtLogin = false
        var hasPendingUpdate = false
    }

    @discardableResult static func populate(_ menu: NSMenu, state: State, target: AnyObject?) -> MenuMoonHeaderView {
        menu.removeAllItems()
        menu.minimumWidth = 252
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = MenuMoonHeaderView(title: state.header.title, subtitle: state.detail, phase: state.header.moonPhase)
        header.view = view
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let toggle = item(state.recording ? "Stop dictation" : "Start dictation", #selector(ApplicationDelegate.toggleDictation))
        showShortcut(state.trigger == .function ? "fn" : state.trigger.displayName, on: toggle)
        menu.addItem(toggle)
        let paste = item("Paste last text", #selector(ApplicationDelegate.repasteLastTranscript))
        if let chord = state.pasteChord { showShortcut(chord.displayName, on: paste) }
        paste.isEnabled = state.canPaste
        menu.addItem(paste)
        if state.keepsHistory { menu.addItem(item("Show history", #selector(ApplicationDelegate.showHistory))) }
        menu.addItem(item(state.paused ? "Resume all shortcuts" : "Pause all shortcuts", #selector(ApplicationDelegate.togglePause)))
        menu.addItem(.separator())
        if state.hasPendingUpdate {
            menu.addItem(item("Install update…", #selector(ApplicationDelegate.checkForUpdates)))
        }
        let login = item("Open at login", #selector(ApplicationDelegate.toggleOpenAtLogin))
        login.state = state.opensAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(ApplicationDelegate.showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : target }
        return view
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    private static func showShortcut(_ shortcut: String, on item: NSMenuItem) {
        let title = item.title
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 218)]
        item.attributedTitle = NSAttributedString(string: title + "\t" + shortcut,
                                                attributes: [.paragraphStyle: paragraph, .font: NSFont.menuFont(ofSize: 13)])
        item.setAccessibilityLabel(title + ", " + shortcut)
    }
}
