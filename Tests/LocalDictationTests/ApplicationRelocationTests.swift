import Foundation
import XCTest
@testable import LocalDictation

final class ApplicationRelocationTests: XCTestCase {
    private let userApplications = URL(fileURLWithPath: "/Users/example/Applications", isDirectory: true)
    private let translocated = URL(fileURLWithPath: "/private/var/folders/example/AppTranslocation/identifier/d/Local Dictation.app")

    private let identifier = "com.example.LocalDictation"

    private func action(_ path: String, original: String? = nil, writable: Bool = true,
                        installed: [String: String] = [:]) -> ApplicationRelocationDecision.Action {
        let source = original ?? path
        return ApplicationRelocationDecision.action(
            bundle: URL(fileURLWithPath: path), original: original.map { URL(fileURLWithPath: $0) },
            userApplications: userApplications, systemApplicationsWritable: writable,
            applicationBundles: { directory in
                installed.keys.map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == directory.path }
                    .sorted { $0.path < $1.path }
            },
            bundleIdentifier: { $0.path == source ? self.identifier : installed[$0.path] })
    }

    func testRelaunchWaitsForTheOriginalProcessBeforeOpeningTheBundle() {
        let command = ApplicationRelaunchCommand(bundle: userApplications.appendingPathComponent("Local Dictation.app"),
                                                processIdentifier: 12345)
        XCTAssertEqual(command.executableURL.path, "/bin/sh")
        XCTAssertEqual(command.arguments, ["-c",
            #"trap '' HUP; while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#,
            "LocalDictation", "12345", "/Users/example/Applications/Local Dictation.app"])
    }

    func testRelaunchPathIsAnArgumentAndCannotBecomeShellCode() throws {
        let path = #"/Users/example/Applications/Owner's \"quoted\" $(touch unwanted) `echo unwanted`; Copy.app"#
        let command = ApplicationRelaunchCommand(bundle: URL(fileURLWithPath: path), processIdentifier: 67890)
        XCTAssertEqual(command.arguments.last, path)
        XCTAssertFalse(command.arguments[1].contains(path))
        let parser = Process()
        parser.executableURL = command.executableURL
        parser.arguments = ["-n"] + command.arguments
        try parser.run()
        parser.waitUntilExit()
        XCTAssertEqual(parser.terminationStatus, 0)
    }

    func testInstalledApplicationsContinueWithoutAnAlert() {
        for path in ["/Applications/Local Dictation.app", "/Users/example/Applications/Local Dictation.app", "/Applications/Utilities/Local Dictation.app"] {
            XCTAssertEqual(action(path), .continueLaunch)
        }
    }

    func testTranslocatedInstalledOriginalRelaunchesWithoutAnAlert() {
        for path in ["/Applications/Local Dictation.app", "/Users/example/Applications/Local Dictation.app"] {
            XCTAssertEqual(action(translocated.path, original: path), .relaunchOriginal(URL(fileURLWithPath: path)))
        }
    }

    func testDownloadsDesktopAndTranslocatedDownloadsOfferMove() {
        for source in ["/Users/example/Downloads/Local Dictation.app", "/Users/example/Desktop/Local Dictation.app"] {
            let expected = ApplicationRelocationDecision.Action.offerMove(source: URL(fileURLWithPath: source),
                destination: URL(fileURLWithPath: "/Applications/Local Dictation.app", isDirectory: true))
            XCTAssertEqual(action(source), expected)
            XCTAssertEqual(action(translocated.path, original: source), expected)
            // No suppression preference: Not Now leaves the next launch's decision unchanged.
            XCTAssertEqual(action(source), expected)
        }
    }

    func testExistingUserInstallationIsReplacedEvenWhenSystemApplicationsIsWritable() {
        let source = "/Users/example/Downloads/Local Dictation.app"
        let existing = "/Users/example/Applications/Local Dictation.app"
        let expected = ApplicationRelocationDecision.Action.offerMove(source: URL(fileURLWithPath: source),
            destination: URL(fileURLWithPath: existing))
        for writable in [true, false] {
            XCTAssertEqual(action(source, writable: writable, installed: [existing: identifier]), expected)
            XCTAssertEqual(action(translocated.path, original: source, writable: writable, installed: [existing: identifier]), expected)
        }
    }

    func testExistingSystemInstallationIsReplacedWithoutFallingBackToASecondCopy() {
        let source = "/Users/example/Downloads/Local Dictation.app"
        let existing = "/Applications/Local Dictation.app"
        let expected = ApplicationRelocationDecision.Action.offerMove(source: URL(fileURLWithPath: source),
            destination: URL(fileURLWithPath: existing))
        for writable in [true, false] {
            XCTAssertEqual(action(source, writable: writable, installed: [existing: identifier]), expected)
            XCTAssertEqual(action(translocated.path, original: source, writable: writable, installed: [existing: identifier]), expected)
        }
    }

    func testBundleIdentityFindsRenamedInstallationAndIgnoresUnrelatedBundles() {
        let source = "/Users/example/Downloads/Local Dictation.app"
        let existing = "/Users/example/Applications/Dictation.app"
        XCTAssertEqual(action(source, installed: [existing: identifier, "/Applications/Local Dictation.app": "com.example.Other"]),
            .offerMove(source: URL(fileURLWithPath: source), destination: URL(fileURLWithPath: existing)))
    }

    func testNoMatchingBundleUsesWritableDirectoryPreference() {
        let source = "/Users/example/Downloads/Local Dictation.app"
        let unrelated = ["/Applications/Other.app": "com.example.Other",
                         "/Users/example/Applications/Other.app": "com.example.Other"]
        for installed in [[:], unrelated] {
            for writable in [true, false] {
                let directory = writable ? URL(fileURLWithPath: "/Applications", isDirectory: true) : userApplications
                XCTAssertEqual(action(source, writable: writable, installed: installed),
                    .offerMove(source: URL(fileURLWithPath: source),
                               destination: directory.appendingPathComponent("Local Dictation.app", isDirectory: true)))
            }
        }
    }

    func testUnwritableSystemDirectoryUsesUserApplications() {
        let source = "/Users/example/Downloads/Local Dictation.app"
        XCTAssertEqual(action(source, writable: false), .offerMove(source: URL(fileURLWithPath: source),
            destination: userApplications.appendingPathComponent("Local Dictation.app", isDirectory: true)))
    }

    func testPathPrefixIsNotMistakenForInstalledLocation() {
        if case .offerMove = action("/Applications backup/Local Dictation.app") {} else { XCTFail("Prefix accepted") }
        if case .offerMove = action("/Users/example/Applications backup/Local Dictation.app") {} else { XCTFail("Prefix accepted") }
    }

    func testUnknownOriginalAndCommandLineBuildContinueSilently() {
        XCTAssertEqual(action(translocated.path), .continueLaunch)
        XCTAssertEqual(action("/Users/example/Projects/local-dictation/.build/debug"), .continueLaunch)
    }
}
