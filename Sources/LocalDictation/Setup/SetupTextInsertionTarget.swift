import AppKit
import DictationCore

/// The setup field belongs to this process. Use its native Accessibility setter without a synchronous AX request
/// back into the application's own main thread. Keep the recording-time field and editor, just as external targets do.
@MainActor final class SetupTextInsertionTarget {
    static let fieldIdentifier = "setup-dictation"
    private weak var field: NSTextField?
    private weak var editor: NSTextView?
    private weak var window: NSWindow?
    private let windowIsActive: (NSWindow) -> Bool

    init?(field: NSTextField, windowIsActive: @escaping (NSWindow) -> Bool = { NSApp.isActive && $0.isKeyWindow }) {
        guard let window = field.window, let editor = field.currentEditor() as? NSTextView else { return nil }
        self.field = field
        self.editor = editor
        self.window = window
        self.windowIsActive = windowIsActive
    }

    static func current() -> SetupTextInsertionTarget? {
        guard NSApp.isActive, let window = NSApp.keyWindow, let content = window.contentView,
              let field = field(in: content), field.currentEditor() === window.firstResponder else { return nil }
        return SetupTextInsertionTarget(field: field)
    }

    private static func field(in view: NSView) -> NSTextField? {
        if let field = view as? SetupTextField { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    var isStillFocused: Bool {
        guard let field, let editor, let window else { return false }
        return windowIsActive(window) && field.window === window && window.firstResponder === editor
            && field.currentEditor() === editor && field.isEditable && field.isEnabled && !field.isHiddenOrHasHiddenAncestor
    }

    func insert(_ text: String) -> InjectionOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard isStillFocused, let editor else { return .targetChanged }
        let before = editor.string as NSString
        let range = editor.selectedRange()
        guard range.location != NSNotFound, NSMaxRange(range) <= before.length else { return .noEditableFocus }
        var insertion = text
        if let first = text.first, !first.isWhitespace, !first.isPunctuation, range.location > 0,
           let previous = before.substring(with: NSRange(location: range.location - 1, length: 1)).last, !previous.isWhitespace {
            insertion = " " + text
        }
        let expected = before.replacingCharacters(in: range, with: insertion)
        editor.setAccessibilitySelectedText(insertion)
        return editor.string == expected ? .inserted(.accessibilityInsertion) : .unconfirmed(clipboard: .preserve)
    }
}
