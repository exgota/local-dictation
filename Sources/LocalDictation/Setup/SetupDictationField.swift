import AppKit
import SwiftUI

/// A native single-line field with a stable identity for recording-time targeting.
struct SetupDictationField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> SetupTextField {
        let field = SetupTextField(string: text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        // A long sentence keeps its newest words in view and marks the cut with an ellipsis.
        field.lineBreakMode = .byTruncatingHead
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Try dictation")
        field.setAccessibilityIdentifier(SetupTextInsertionTarget.fieldIdentifier)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SetupTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class SetupTextField: NSTextField {
    private var focusObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        guard let window else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focus() }
        }
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    private func focus() {
        guard NSApp.isActive, let window, window.isKeyWindow else { return }
        window.makeFirstResponder(self)
        if let editor = currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    isolated deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
}
