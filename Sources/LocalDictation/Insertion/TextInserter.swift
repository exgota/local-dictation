import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DictationCore

/// The application and element that had focus when dictation started.
@MainActor struct InsertionTarget {
    let processIdentifier: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    let focusedElement: AXUIElement?

    /// The same target with the element now focused in its application, for a target whose first query found none. Nil
    /// when the target already has an element, when another application is frontmost, or when the query finds none.
    func withFocusedElement() -> InsertionTarget? {
        guard focusedElement == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
            let element = Accessibility.focusedElement(of: processIdentifier)
        else { return nil }
        return InsertionTarget(
            processIdentifier: processIdentifier, applicationName: applicationName, bundleIdentifier: bundleIdentifier,
            focusedElement: element)
    }

    /// Identifies the application across dictations: its bundle identifier, or its name when it has none.
    var applicationKey: String { bundleIdentifier ?? applicationName }

    static func current() -> InsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return InsertionTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "the application",
            bundleIdentifier: application.bundleIdentifier,
            focusedElement: Accessibility.focusedElement(of: application.processIdentifier))
    }

    /// True when the same application is frontmost and the same element still has focus. Without element identity the
    /// target cannot be verified, so automatic insertion is refused.
    func isStillFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
            let focusedElement, let now = Accessibility.focusedElement(of: processIdentifier)
        else { return false }
        return CFEqual(focusedElement, now)
    }
}

enum Accessibility {
    /// The focused element of `processIdentifier`. Chromium-based browsers and Electron apps build their accessibility
    /// tree only once an assistive client asks, and then a moment later. When none is reported, both switches they
    /// respond to are set (`AXManualAccessibility` for Electron, `AXEnhancedUserInterface` for Chrome) and the query
    /// runs once more; if it still finds none, the caller asks again shortly.
    static func focusedElement(of processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        if let element = element(application, kAXFocusedUIElementAttribute) { return element }
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return element(application, kAXFocusedUIElementAttribute)
    }

    static func describe(_ element: AXUIElement, processIdentifier: pid_t) -> FocusedElementDescription {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        let secureInputHolder = SecureInputMonitor.currentHolder()?.processIdentifier
        return FocusedElementDescription(
            isSecure: subrole == kAXSecureTextFieldSubrole || secureInputHolder == processIdentifier,
            isEditable: role.map(textRoles.contains) == true || isSettable(element, kAXValueAttribute),
            acceptsSelectedTextInsertion: isSettable(element, kAXSelectedTextAttribute),
            isValueReadable: string(element, kAXValueAttribute) != nil)
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func integer(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &range)
        else { return nil }
        return range
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
}

/// Delivers text into one target through the chain chosen by `InjectionPlanner`.
@MainActor final class TextInserter: TextInjecting {
    private let target: InsertionTarget
    private let element: AXUIElement
    private let onLanded: @MainActor () -> Void

    private init(target: InsertionTarget, element: AXUIElement, onLanded: @escaping @MainActor () -> Void) {
        self.target = target
        self.element = element
        self.onLanded = onLanded
    }

    /// Probes the target's focused element, then inserts `text`. Text is never sent to a different element.
    /// `onLanded` runs after Accessibility confirms arrival, or on the first clipboard read before the clipboard is restored.
    static func insert(
        _ text: String, into target: InsertionTarget, onLanded: @escaping @MainActor () -> Void = {}
    ) async -> InjectionOutcome {
        guard target.isStillFocused(), let element = target.focusedElement else {
            return target.focusedElement == nil ? .noEditableFocus : .targetChanged
        }
        let description = Accessibility.describe(element, processIdentifier: target.processIdentifier)
        let decision = InjectionPlanner.decide(
            for: description,
            applicationIgnoresAccessibilityInsertion: applicationsIgnoringAccessibilityInsertion.contains(target.applicationKey))
        let inserter = TextInserter(target: target, element: element, onLanded: onLanded)
        return await InjectionChain.run(prefixedForInsertionPoint(text, in: element), decision: decision, injector: inserter)
    }

    /// Applications whose fields accepted an Accessibility insertion and read back unchanged during this session.
    private static var applicationsIgnoringAccessibilityInsertion: Set<String> = []

    func isTargetStillFocused() -> Bool { target.isStillFocused() }

    /// A readable snapshot of the field: its value, length and insertion point. Nil parts mean Accessibility does not
    /// expose them.
    private struct FieldState: Equatable {
        let value: String?
        let characterCount: Int?
        let range: CFRange?

        static func == (left: FieldState, right: FieldState) -> Bool {
            left.value == right.value && left.characterCount == right.characterCount
                && left.range?.location == right.range?.location && left.range?.length == right.range?.length
        }

        var isReadable: Bool { value != nil }
    }

    private func fieldState() -> FieldState {
        FieldState(
            value: Accessibility.string(element, kAXValueAttribute),
            characterCount: Accessibility.integer(element, kAXNumberOfCharactersAttribute),
            range: Accessibility.selectedRange(element))
    }

    /// True when the field shows that `text` arrived since `before`: the value has changed and either the insertion
    /// point sits where the new text ends or the value contains the text. The insertion point and length are read
    /// first, and the full value only once one of them has moved or cannot be read, so a long document is not read in
    /// full on every check.
    private func showsArrival(of text: String, since before: FieldState) -> Bool {
        let range = Accessibility.selectedRange(element)
        let characterCount = Accessibility.integer(element, kAXNumberOfCharactersAttribute)
        if let beforeRange = before.range, let range, let beforeCount = before.characterCount, let characterCount,
            range.location == beforeRange.location, range.length == beforeRange.length, characterCount == beforeCount
        {
            return false
        }
        guard let value = Accessibility.string(element, kAXValueAttribute), value != before.value else { return false }
        if let beforeRange = before.range, range?.location == beforeRange.location + text.utf16.count { return true }
        return value.contains(text)
    }

    /// Checks the field every 20 ms until it shows that `text` arrived or `timeout` passes. Not delivered only when the
    /// field is readable and still exactly as before. Uncertain otherwise.
    private func confirm(
        _ text: String, since before: FieldState, timeout: TimeInterval, clipboardChangeCount: Int
    ) async -> InjectionAttempt {
        let deadline = monotonicSeconds() + timeout
        while true {
            if showsArrival(of: text, since: before) { return .delivered }
            if monotonicSeconds() >= deadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return before.isReadable && fieldState() == before
            ? .notDelivered : .uncertain(clipboard: .writeIfUnchanged(changeCount: clipboardChangeCount))
    }

    /// Sets `AXSelectedText` and reads the field back for up to 0.5 s. Some web views accept the call without
    /// inserting; their field reads back unchanged, so the chain can then try paste without inserting twice.
    func insertViaAccessibility(_ text: String) async -> InjectionAttempt {
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let before = fieldState()
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return .notDelivered }
        let attempt = await confirm(text, since: before, timeout: 0.5, clipboardChangeCount: clipboardChangeCount)
        switch attempt {
        case .delivered: onLanded()
        case .notDelivered: Self.applicationsIgnoringAccessibilityInsertion.insert(target.applicationKey)
        case .uncertain: break
        }
        return attempt
    }

    /// Pastes through the clipboard. Delivered when a process read the clipboard; otherwise uncertain. Where the field
    /// is readable, the previous clipboard is restored as soon as the field shows the text.
    func paste(_ text: String) async -> InjectionAttempt {
        let before = fieldState()
        let transaction = ClipboardPasteTransaction(pasteboard: SystemPasteboard(), clock: monotonicSeconds)
        let outcome = await transaction.paste(
            text, postPasteShortcut: { Self.postKey(VirtualKey.letterV, flags: .maskCommand) }, onLanded: onLanded,
            showsText: { [self] in before.isReadable && showsArrival(of: text, since: before) })
        switch outcome {
        case .landed:
            return .delivered
        case .writeFailed:
            return .notDelivered
        case .notRead:
            // The posted Command-V may still be handled late, so the transcript stays on the clipboard (never the
            // previous contents, which a late paste would insert) and nothing else is tried.
            return .uncertain(clipboard: .preserve)
        }
    }

    static func postKey(_ keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: HotkeyEventTap.syntheticEventMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    static func placeOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func placeOnClipboardIfUnchanged(_ text: String, since changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount, pasteboard.string(forType: .string) != text else { return }
        placeOnClipboard(text)
    }

    /// Adds a separating space when the text starts with a character that is neither whitespace nor punctuation and the
    /// insertion point directly follows a non-space character, so consecutive dictations do not run together. Applies
    /// only where Accessibility exposes the text and selection.
    private static func prefixedForInsertionPoint(_ text: String, in element: AXUIElement) -> String {
        guard let first = text.first, !first.isWhitespace, !first.isPunctuation,
            let range = Accessibility.selectedRange(element), range.location > 0
        else { return text }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previous) else { return text }
        var characterValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &characterValue) == .success,
            let character = (characterValue as? String)?.last
        else { return text }
        return character.isWhitespace ? text : " " + text
    }
}

/// The general pasteboard. The transcript is written with a data provider, so the target's read on Command-V calls
/// back here and confirms the paste.
@MainActor final class SystemPasteboard: NSObject, PasteboardAccessing, NSPasteboardItemDataProvider {
    private let pasteboard = NSPasteboard.general
    private var onDemandText: String?
    private var onRead: (@MainActor () -> Void)?

    var changeCount: Int { pasteboard.changeCount }

    func takeSnapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    func restore(_ snapshot: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
    }

    func writeOnDemand(_ text: String, onRead: @escaping @MainActor () -> Void) -> (succeeded: Bool, changeCount: Int) {
        onDemandText = text
        self.onRead = onRead
        let changeCount = pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        // Clipboard managers that honor the nspasteboard.org conventions skip transient entries without reading them.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let succeeded = pasteboard.writeObjects([item])
        if !succeeded { onDemandText = nil; self.onRead = nil }
        return (succeeded, changeCount)
    }

    func writePlainText(_ text: String) {
        onDemandText = nil
        TextInserter.placeOnClipboard(text)
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // The pasteboard calls this on the main thread, or the block below runs there synchronously.
        nonisolated(unsafe) let item = item
        let provide = {
            MainActor.assumeIsolated {
                guard let onDemandText = self.onDemandText else { return }
                item.setString(onDemandText, forType: type)
                self.onRead?()
            }
        }
        if Thread.isMainThread { provide() } else { DispatchQueue.main.sync(execute: provide) }
    }
}
