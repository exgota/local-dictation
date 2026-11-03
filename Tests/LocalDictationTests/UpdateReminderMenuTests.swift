import AppKit
import XCTest
@testable import LocalDictation

final class UpdateReminderMenuTests: XCTestCase {
    @MainActor func testUpdateCommandIsAbsentWithoutPendingUpdate() {
        let menu = NSMenu()
        for header in StatusMenu.HeaderState.allCases {
            StatusMenu.populate(menu, state: .init(header: header), target: nil)
            XCTAssertNil(menu.item(withTitle: "Install update…"))
        }
    }

    @MainActor func testPendingUpdateStartsSecondCommandGroupInEveryHeaderState() throws {
        let menu = NSMenu()
        let target = NSObject()
        for header in StatusMenu.HeaderState.allCases {
            StatusMenu.populate(menu, state: .init(header: header, hasPendingUpdate: true), target: target)
            let update = try XCTUnwrap(menu.item(withTitle: "Install update…"))
            let index = menu.index(of: update)
            XCTAssertTrue(menu.item(at: index - 1)?.isSeparatorItem == true)
            XCTAssertEqual(menu.item(at: index + 1)?.title, "Open at login")
            XCTAssertEqual(update.action, #selector(ApplicationDelegate.checkForUpdates))
            XCTAssertTrue(update.target === target)
            XCTAssertTrue(update.isEnabled)
            XCTAssertEqual(update.keyEquivalent, "")
            XCTAssertEqual(menu.items.first?.view?.frame.height, 32)
        }
    }

    @MainActor func testRebuildingMenuKeepsOneReminderAndClearingPendingUpdateRemovesIt() {
        let menu = NSMenu()
        StatusMenu.populate(menu, state: .init(keepsHistory: true, hasPendingUpdate: true), target: nil)
        StatusMenu.populate(menu, state: .init(keepsHistory: true, hasPendingUpdate: true), target: nil)
        XCTAssertEqual(menu.items.filter { $0.title == "Install update…" }.count, 1)
        XCTAssertNotNil(menu.item(withTitle: "Show history"))
        StatusMenu.populate(menu, state: .init(keepsHistory: true), target: nil)
        XCTAssertNil(menu.item(withTitle: "Install update…"))
        let loginIndex = menu.indexOfItem(withTitle: "Open at login")
        XCTAssertTrue(menu.item(at: loginIndex - 1)?.isSeparatorItem == true)
    }
}
