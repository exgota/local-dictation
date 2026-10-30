import XCTest

@testable import TextProcessing

final class TranscriptProfileTests: XCTestCase {
    func testVerbatimOnlyEnablesVocabularyCorrections() {
        XCTAssertEqual(TranscriptProfile.verbatim.defaultOptions(), ProcessingOptions(vocabularyCorrections: true))
        XCTAssertEqual(
            TranscriptProfile.verbatim.defaultOptions(vocabularyCorrectionsEnabled: false), ProcessingOptions())
        XCTAssertEqual(TranscriptProfile.verbatim.displayName, "Default")
    }

    func testChatEnablesEverything() {
        let options = TranscriptProfile.chat.defaultOptions()
        XCTAssertEqual(
            options,
            ProcessingOptions(
                vocabularyCorrections: true, spokenPunctuation: true, scratchThat: true, fillerRemoval: true,
                capitalizeFirst: true, terminalPunctuation: true))
    }

    func testCodeIsVerbatimAndNeverSubmits() {
        XCTAssertEqual(TranscriptProfile.code.defaultOptions(), ProcessingOptions(vocabularyCorrections: true))
        XCTAssertFalse(TranscriptProfile.code.submitsWithReturn(userPreference: true))
        XCTAssertEqual(TranscriptProfile.code.displayName, "Code/Terminal")
    }

    func testSubmitsWithReturnOnlyForChatWhenRequested() {
        XCTAssertTrue(TranscriptProfile.chat.submitsWithReturn(userPreference: true))
        XCTAssertFalse(TranscriptProfile.chat.submitsWithReturn(userPreference: false))
        XCTAssertFalse(TranscriptProfile.verbatim.submitsWithReturn(userPreference: true))
        XCTAssertFalse(TranscriptProfile.suppressed.submitsWithReturn(userPreference: true))
    }

    func testSuppressedProducesNoText() {
        XCTAssertFalse(TranscriptProfile.suppressed.producesText)
        XCTAssertEqual(TranscriptProfile.suppressed.defaultOptions(), ProcessingOptions())
        XCTAssertTrue(TranscriptProfile.chat.producesText)
    }

    func testProcessingOptionsDefaultToAllOff() {
        XCTAssertEqual(
            ProcessingOptions(),
            ProcessingOptions(
                vocabularyCorrections: false, spokenPunctuation: false, scratchThat: false, fillerRemoval: false,
                capitalizeFirst: false, terminalPunctuation: false))
    }
}

final class ProfileResolverTests: XCTestCase {
    func testBuiltInBundleIdentifiers() {
        let resolver = ProfileResolver()
        let suppressed = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
            "com.dashlane.Dashlane", "com.lastpass.LastPass", "org.keepassxc.keepassxc",
        ]
        let code = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        ]
        let chat = [
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
            "com.apple.MobileSMS",
        ]
        for identifier in suppressed { XCTAssertEqual(resolver.profile(forBundleIdentifier: identifier), .suppressed) }
        for identifier in code { XCTAssertEqual(resolver.profile(forBundleIdentifier: identifier), .code) }
        for identifier in chat { XCTAssertEqual(resolver.profile(forBundleIdentifier: identifier), .chat) }
    }

    func testUnknownAndMissingBundleUseConfiguredDefault() {
        XCTAssertEqual(ProfileResolver().profile(forBundleIdentifier: "com.example.Notes"), .verbatim)
        XCTAssertEqual(ProfileResolver().profile(forBundleIdentifier: nil), .verbatim)
        let configured = ProfileResolver(defaultProfile: .chat)
        XCTAssertEqual(configured.profile(forBundleIdentifier: "com.example.Notes"), .chat)
        XCTAssertEqual(configured.profile(forBundleIdentifier: nil), .chat)
    }

    func testOverridesWinOverBuiltIns() {
        let resolver = ProfileResolver(overrides: [
            "com.apple.Terminal": .chat, "com.1password.1password": .verbatim, "com.example.Notes": .code,
        ])
        XCTAssertEqual(resolver.profile(forBundleIdentifier: "com.apple.Terminal"), .chat)
        XCTAssertEqual(resolver.profile(forBundleIdentifier: "com.1password.1password"), .verbatim)
        XCTAssertEqual(resolver.profile(forBundleIdentifier: "com.example.Notes"), .code)
        XCTAssertEqual(resolver.profile(forBundleIdentifier: "com.microsoft.VSCode"), .code)
    }

    func testBundleIdentifierComparisonIgnoresCase() {
        XCTAssertEqual(ProfileResolver().profile(forBundleIdentifier: "COM.APPLE.TERMINAL"), .code)
    }

    func testCodableRoundTrip() throws {
        let resolver = ProfileResolver(overrides: ["com.example.Notes": .chat], defaultProfile: .code)
        let decoded = try JSONDecoder().decode(ProfileResolver.self, from: JSONEncoder().encode(resolver))
        XCTAssertEqual(decoded, resolver)
    }
}

final class TranscriptProcessorTests: XCTestCase {
    private let processor = TranscriptProcessor()

    func testEmptyInputGivesEmptyOutput() {
        let all = TranscriptProfile.chat.defaultOptions()
        XCTAssertEqual(processor.process("", options: all, corrections: .seed), "")
        XCTAssertEqual(processor.process("   \n ", options: all, corrections: .seed), "")
    }

    func testNoOptionsOnlyNormalizesWhitespace() {
        XCTAssertEqual(
            processor.process("  um  so   I like it  ", options: ProcessingOptions(), corrections: .seed),
            "um so I like it")
    }

    func testCombinedExampleRunsAllStepsInOrder() {
        let raw =
            "um so I think we should, uh, ship it. send it tomorrow, scratch that, send it today period "
            + "new line cloud code is, like, great"
        let output = processor.process(raw, options: TranscriptProfile.chat.defaultOptions(), corrections: .seed)
        XCTAssertEqual(output, "So I think we should, ship it. Send it today.\nClaude Code is, great.")
    }

    func testVerbatimProfileKeepsFillersButCorrectsVocabulary() {
        let output = processor.process(
            "um open cloud code", options: TranscriptProfile.verbatim.defaultOptions(), corrections: .seed)
        XCTAssertEqual(output, "um open Claude Code")
    }

    func testStepsAreIndividuallyOptional() {
        let corrections = VocabularyCorrections.seed
        XCTAssertEqual(
            processor.process("hi comma world", options: ProcessingOptions(spokenPunctuation: true), corrections: corrections),
            "hi, world")
        XCTAssertEqual(
            processor.process("hi comma world", options: ProcessingOptions(), corrections: corrections),
            "hi comma world")
        XCTAssertEqual(
            processor.process("cloud code", options: ProcessingOptions(vocabularyCorrections: true), corrections: corrections),
            "Claude Code")
        XCTAssertEqual(
            processor.process("hello", options: ProcessingOptions(terminalPunctuation: true), corrections: corrections),
            "hello.")
    }

    func testScratchThatRunsBeforeSpokenPunctuation() {
        // The spoken "period" is not yet a "." when scratch that runs, so the sentence starts at the beginning of the
        // text and scratch that deletes "one period two" with the command.
        let options = ProcessingOptions(spokenPunctuation: true, scratchThat: true)
        XCTAssertEqual(
            processor.process("one period two scratch that three", options: options, corrections: .init()), "three")
    }

    func testVocabularyRunsBeforeCapitalization() {
        let options = ProcessingOptions(vocabularyCorrections: true, capitalizeFirst: true)
        XCTAssertEqual(processor.process("work tree list", options: options, corrections: .seed), "Worktree list")
    }

    func testNewlinesSurviveWhitespaceNormalization() {
        XCTAssertEqual(
            processor.process("a \n  b", options: ProcessingOptions(), corrections: .init()), "a\nb")
    }
}

final class ProfileResolverDecodingTests: XCTestCase {
    func testUnknownProfileDropsOnlyThatOverride() throws {
        let json = #"{"overrides": {"com.example.one": "chat", "com.example.two": "shouting"}, "defaultProfile": "code"}"#
        let resolver = try JSONDecoder().decode(ProfileResolver.self, from: Data(json.utf8))
        XCTAssertEqual(resolver.overrides, ["com.example.one": .chat])
        XCTAssertEqual(resolver.defaultProfile, .code)
    }

    func testMissingDefaultFallsBackToVerbatim() throws {
        let resolver = try JSONDecoder().decode(ProfileResolver.self, from: Data(#"{"overrides": {"com.example.one": "suppressed"}}"#.utf8))
        XCTAssertEqual(resolver.overrides, ["com.example.one": .suppressed])
        XCTAssertEqual(resolver.defaultProfile, .verbatim)
    }

    func testRoundTrip() throws {
        let original = ProfileResolver(overrides: ["com.example.one": .chat], defaultProfile: .code)
        let decoded = try JSONDecoder().decode(ProfileResolver.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
