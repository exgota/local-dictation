import Foundation

/// What Accessibility reports about the focused element, reduced to what the injection choice depends on.
public struct FocusedElementDescription: Equatable, Sendable {
    /// A password field (`AXSecureTextField`), or an element of an application that holds Secure Event Input. Never
    /// typed into.
    public var isSecure: Bool
    /// The element accepts text: its role is a text field, text area or combo box, or its `AXValue` is settable.
    public var isEditable: Bool
    /// `AXSelectedText` is settable, so text can be inserted without the clipboard.
    public var acceptsSelectedTextInsertion: Bool
    /// `AXValue` can be read, so an Accessibility insertion can be confirmed or ruled out by reading back.
    public var isValueReadable: Bool

    public init(isSecure: Bool, isEditable: Bool, acceptsSelectedTextInsertion: Bool, isValueReadable: Bool) {
        self.isSecure = isSecure
        self.isEditable = isEditable
        self.acceptsSelectedTextInsertion = acceptsSelectedTextInsertion
        self.isValueReadable = isValueReadable
    }
}

public enum InjectionMethod: String, Equatable, Sendable {
    /// Set `AXSelectedText` and confirm by reading the element back.
    case accessibilityInsertion
    /// Clipboard and Command-V, signaled when a process reads the clipboard.
    case paste
}

public enum InjectionDecision: Equatable, Sendable {
    case refuseSecureField
    case noEditableFocus
    /// Try Accessibility insertion, followed by paste if it demonstrably fails.
    case accessibilityThenPaste
    /// Try paste only.
    case paste
}

public enum InjectionPlanner {
    /// Chooses the methods to try, in order, from a probe of the focused element. `applicationIgnoresAccessibilityInsertion`
    /// is true when an earlier Accessibility insertion in the same application was accepted but read back unchanged, as
    /// Chromium-based browsers and Electron apps do; paste then goes first, which saves the 0.5 s read-back.
    public static func decide(
        for element: FocusedElementDescription?, applicationIgnoresAccessibilityInsertion: Bool = false
    ) -> InjectionDecision {
        guard let element else { return .noEditableFocus }
        if element.isSecure { return .refuseSecureField }
        guard element.isEditable || element.acceptsSelectedTextInsertion else { return .noEditableFocus }
        // Accessibility insertion goes first only when the field can be read back. Without a read-back its outcome can
        // be neither confirmed nor ruled out, and paste, which a clipboard read signals, is the better first
        // choice.
        if element.acceptsSelectedTextInsertion && element.isValueReadable && !applicationIgnoresAccessibilityInsertion {
            return .accessibilityThenPaste
        }
        return .paste
    }
}

/// Whether a fallback may put the transcript on the clipboard.
public enum ClipboardFallback: Equatable, Sendable {
    /// The paste transaction already handled the clipboard, or another process may have changed it.
    case preserve
    /// No clipboard operation was performed; write only if this change count is still current.
    case writeIfUnchanged(changeCount: Int)
}

/// What one injection method achieved.
public enum InjectionAttempt: Equatable, Sendable {
    /// Accessibility read-back shows arrival, or a process read the clipboard during a paste.
    case delivered
    /// The text demonstrably did not arrive (the field reads back unchanged), so another method is safe.
    case notDelivered
    /// Something was sent that may still arrive. Trying another method could insert the text twice.
    case uncertain(clipboard: ClipboardFallback)
}

/// The platform operations that `InjectionChain` calls.
@MainActor public protocol TextInjecting: AnyObject {
    func isTargetStillFocused() -> Bool
    func insertViaAccessibility(_ text: String) async -> InjectionAttempt
    func paste(_ text: String) async -> InjectionAttempt
}

public enum InjectionOutcome: Equatable, Sendable {
    case inserted(InjectionMethod)
    case refusedSecureField
    case noEditableFocus
    /// Focus moved away from the original target before the text could be delivered.
    case targetChanged
    /// No method could confirm delivery. The clipboard policy preserves any newer copy.
    case unconfirmed(clipboard: ClipboardFallback)
    /// The delivering task was cancelled before a method started.
    case cancelled
}

public enum InjectionChain {
    /// Tries each method in order until one reports delivery. The next method runs only after a method demonstrably
    /// did not deliver. Once a method may have worked, the chain stops with `.unconfirmed`, because another method
    /// could insert the text twice. The chain checks before every attempt that the original target still has focus, so
    /// no attempt starts against a different element.
    @MainActor
    public static func run(_ text: String, decision: InjectionDecision, injector: TextInjecting) async -> InjectionOutcome {
        let methods: [InjectionMethod]
        switch decision {
        case .refuseSecureField: return .refusedSecureField
        case .noEditableFocus: return .noEditableFocus
        case .accessibilityThenPaste: methods = [.accessibilityInsertion, .paste]
        case .paste: methods = [.paste]
        }
        for method in methods {
            // Escape cancels the delivering task. A cancelled task starts no further method.
            if Task.isCancelled { return .cancelled }
            guard injector.isTargetStillFocused() else { return .targetChanged }
            let attempt: InjectionAttempt
            switch method {
            case .accessibilityInsertion: attempt = await injector.insertViaAccessibility(text)
            case .paste: attempt = await injector.paste(text)
            }
            switch attempt {
            case .delivered: return .inserted(method)
            case .notDelivered:
                if method == .paste { return .unconfirmed(clipboard: .preserve) }
                continue
            case .uncertain(let clipboard):
                return .unconfirmed(clipboard: method == .paste ? .preserve : clipboard)
            }
        }
        return .unconfirmed(clipboard: .preserve)
    }
}
