import AppKit
import DictationCore
import SwiftUI

/// Two widths for every control on the shared edge: one for menus of names, one for short values.
@MainActor enum SettingsControlWidth {
    static let behaviors = ["Press to Start and Stop", "Hold to Record", "Hold or Double-Press to Keep Recording"]
    static let wide: CGFloat = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: behaviors)
        button.sizeToFit()
        return ceil(button.frame.width)
    }()
    static let narrow: CGFloat = 150
}

/// A real NSPopUpButton at an exact width, so equal-width menus render with equal bezels.
struct SettingsPopUpButton: NSViewRepresentable {
    let items: [String]
    @Binding var selection: Int
    let width: CGFloat
    var enabled = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24), pullsDown: false)
        for item in items {
            if item == "-" { button.menu?.addItem(.separator()) } else { button.addItem(withTitle: item) }
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let current = button.itemArray.map { $0.isSeparatorItem ? "-" : $0.title }
        if current != items {
            button.removeAllItems()
            for item in items {
                if item == "-" { button.menu?.addItem(.separator()) } else { button.addItem(withTitle: item) }
            }
        }
        if button.indexOfSelectedItem != selection { button.selectItem(at: selection) }
        button.isEnabled = enabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsPopUpButton
        init(_ parent: SettingsPopUpButton) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) { parent.selection = sender.indexOfSelectedItem }
    }
}

/// The standard add and remove control that sits under a list.
struct SettingsAddRemoveControl: NSViewRepresentable {
    var removeEnabled: Bool
    let add: () -> Void
    let remove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: [NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!],
            trackingMode: .momentary, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        control.segmentStyle = .smallSquare
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.setEnabled(removeEnabled, forSegment: 1)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsAddRemoveControl
        init(_ parent: SettingsAddRemoveControl) { self.parent = parent }
        @objc func clicked(_ sender: NSSegmentedControl) {
            if sender.selectedSegment == 0 { parent.add() } else { parent.remove() }
        }
    }
}

/// The same native bezel as the pop-up menus, so the shortcut fields share their fill and corners.
struct SettingsShortcutBezel: NSViewRepresentable {
    let title: String
    let dimmed: Bool
    let recording: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .push
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: recording ? NSColor.white : (dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor),
        ])
        button.bezelColor = recording ? .controlAccentColor : nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: SettingsControlWidth.narrow, height: nsView.intrinsicContentSize.height)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsShortcutBezel
        init(_ parent: SettingsShortcutBezel) { self.parent = parent }
        @objc func clicked() { parent.action() }
    }
}


/// Read-only selectable text that reports its selection, so a misheard word can become a correction.
struct HistorySelectableText: NSViewRepresentable {
    let text: String
    var identity: Int64?
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        if view.string != text || context.coordinator.displayedIdentity != identity {
            context.coordinator.displayedIdentity = identity
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HistorySelectableText
        var displayedIdentity: Int64?
        init(_ parent: HistorySelectableText) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            parent.selection = range.length > 0 ? (view.string as NSString).substring(with: range) : ""
        }
    }
}


struct SettingsShortcutField: View {
    @Binding var chord: KeyChord?
    var suspendShortcuts: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        SettingsShortcutBezel(title: recording ? "Type Shortcut" : (chord?.displayName ?? "Record Shortcut"),
                              dimmed: recording || chord == nil, recording: recording) { recording ? stop() : start() }
        .overlay(alignment: .trailing) {
            if chord != nil && !recording {
                Button { chord = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear Shortcut").padding(.trailing, 7)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        suspendShortcuts(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown { stop(); return event }
            let modifiers = ModifierSet(eventFlags: UInt64(event.modifierFlags.rawValue))
            if event.keyCode == VirtualKey.escape { stop(); return nil }
            if event.keyCode == 51 && modifiers.isEmpty { chord = nil; stop(); return nil }
            guard !modifiers.intersection([.control, .option, .command]).isEmpty else { NSSound.beep(); return nil }
            chord = KeyChord(keyCode: event.keyCode, modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        suspendShortcuts(false)
    }
}

struct DictationKeyCaptureSheet: View {
    var suspendShortcuts: (Bool) -> Void
    let finish: (TriggerKey?) -> Void
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 16) {
            Text("Press the key you want to use.").font(.headline)
            HStack { Spacer(); Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 320)
        .onAppear {
            suspendShortcuts(true)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                if event.type == .flagsChanged {
                    guard EventFlagBits.isModifierDown(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) == true else { return event }
                    switch event.keyCode {
                    case VirtualKey.function: finish(.function)
                    case VirtualKey.rightCommand: finish(.rightCommand)
                    case VirtualKey.rightOption: finish(.rightOption)
                    default: return event
                    }
                    return nil
                }
                if event.keyCode == VirtualKey.escape { finish(nil); return nil }
                let modifiers = ModifierSet(eventFlags: UInt64(event.modifierFlags.rawValue))
                guard VirtualKey.functionKeys[event.keyCode] != nil || !modifiers.isEmpty else { NSSound.beep(); return nil }
                finish(.key(KeyChord(keyCode: event.keyCode, modifiers: modifiers)))
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            suspendShortcuts(false)
        }
    }
}
