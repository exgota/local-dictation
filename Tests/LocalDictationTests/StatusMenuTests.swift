import AppKit
import DictationCore
import XCTest
@testable import LocalDictation

@MainActor private final class MenuActionTarget: NSObject {
    var pasteCount = 0
    @objc func repasteLastTranscript() { pasteCount += 1 }
}

final class StatusMenuTests: XCTestCase {
    @MainActor func testMenuStartsWithAnActionAndHasNoCustomRowsOrAttributedLegends() {
        let menu = NSMenu()
        for pendingUpdate in [false, true] {
            StatusMenu.populate(menu, state: .init(hasPendingUpdate: pendingUpdate), target: nil)
            XCTAssertEqual(menu.items.first?.title, "Start dictation")
            XCTAssertEqual(menu.items.first?.keyEquivalent, "")
            XCTAssertTrue(menu.items.allSatisfy { $0.view == nil && $0.attributedTitle == nil })
        }
    }

    @MainActor func testPasteKeyEquivalentActuallyInvokesTheMenuAction() throws {
        let target = MenuActionTarget()
        let menu = NSMenu()
        StatusMenu.populate(menu, state: .init(canPaste: true), target: target)
        let item = try XCTUnwrap(menu.item(withTitle: "Paste last text"))
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .shift])
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "V", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: VirtualKey.letterV))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.pasteCount, 1)
    }

    @MainActor func testConfiguredShortcutsUseNativeModifiersAndUnsupportedKeysStayEmpty() throws {
        let menu = NSMenu()
        StatusMenu.populate(menu, state: .init(pasteChord: KeyChord(keyCode: 122, modifiers: [.control]),
                                               pauseChord: KeyChord(keyCode: 9, modifiers: [.command, .shift])), target: nil)
        XCTAssertEqual(menu.item(withTitle: "Paste last text")?.keyEquivalent, String(UnicodeScalar(NSF1FunctionKey)!))
        XCTAssertEqual(menu.item(withTitle: "Paste last text")?.keyEquivalentModifierMask, [.control])
        XCTAssertEqual(menu.item(withTitle: "Pause all shortcuts")?.keyEquivalent, "v")
        XCTAssertEqual(menu.item(withTitle: "Pause all shortcuts")?.keyEquivalentModifierMask, [.command, .shift])
        for code in [VirtualKey.function, VirtualKey.rightOption, UInt16.max] {
            StatusMenu.populate(menu, state: .init(pasteChord: KeyChord(keyCode: code, modifiers: [.option])), target: nil)
            XCTAssertEqual(menu.item(withTitle: "Paste last text")?.keyEquivalent, "")
        }
    }
}
