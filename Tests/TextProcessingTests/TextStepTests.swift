import XCTest

@testable import TextProcessing

final class SpokenPunctuationTests: XCTestCase {
    func testEachCommand() {
        let cases: [(String, String)] = [
            ("hello period", "hello."),
            ("hello full stop", "hello."),
            ("hello comma world", "hello, world"),
            ("really question mark", "really?"),
            ("wow exclamation mark", "wow!"),
            ("wow exclamation point", "wow!"),
            ("note colon yes", "note: yes"),
            ("one semicolon two", "one; two"),
            ("first new line second", "first\nsecond"),
            ("first new paragraph second", "first\n\nsecond"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenPunctuation.apply(to: input), expected, input)
        }
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "Hello COMMA world Period"), "Hello, world.")
        XCTAssertEqual(SpokenPunctuation.apply(to: "x New Paragraph b"), "x\n\nb")
    }

    func testRemovesModelPunctuationAroundCommand() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "tomorrow, period."), "tomorrow.")
        XCTAssertEqual(SpokenPunctuation.apply(to: "yes, comma, then no"), "yes, then no")
        XCTAssertEqual(SpokenPunctuation.apply(to: "ok. Question mark."), "ok?")
    }

    func testKeepsSentencePeriodBeforeNewlineCommands() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "Hello. New paragraph. World"), "Hello.\n\nWorld")
        XCTAssertEqual(SpokenPunctuation.apply(to: "Hello, new line. World"), "Hello\nWorld")
    }

    func testSpacingAroundMultipleCommands() {
        XCTAssertEqual(
            SpokenPunctuation.apply(to: "dear sam comma new line thanks period"), "dear sam,\nthanks.")
    }

    func testLeavesNounUsageAlone() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "the period of the experiment"), "the period of the experiment")
        XCTAssertEqual(SpokenPunctuation.apply(to: "add a colon here"), "add a colon here")
    }

    func testTextWithoutCommandsIsUnchanged() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "nothing  to see ,here"), "nothing  to see ,here")
    }

    func testDoesNotMatchInsideWords() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "periodic commas"), "periodic commas")
    }
}

final class ScratchThatTests: XCTestCase {
    func testDeletesCurrentSentenceThroughCommand() {
        XCTAssertEqual(
            ScratchThat.apply(to: "Let's send it tomorrow, scratch that, send it today."), "send it today.")
    }

    func testExampleWithCapitalizationOn() {
        let options = ProcessingOptions(scratchThat: true, capitalizeFirst: true)
        let output = TranscriptProcessor().process(
            "Let's send it tomorrow, scratch that, send it today.", options: options, corrections: .init())
        XCTAssertEqual(output, "Send it today.")
    }

    func testExampleWithCapitalizationOff() {
        let options = ProcessingOptions(scratchThat: true)
        let output = TranscriptProcessor().process(
            "Let's send it tomorrow, scratch that, send it today.", options: options, corrections: .init())
        XCTAssertEqual(output, "send it today.")
    }

    func testOnlyCurrentSentenceIsDeleted() {
        XCTAssertEqual(
            ScratchThat.apply(to: "First one. Second wrong scratch that second right."),
            "First one. second right.")
        XCTAssertEqual(ScratchThat.apply(to: "Really? Maybe not scratch that yes."), "Really? yes.")
        XCTAssertEqual(ScratchThat.apply(to: "Line one\nline two scratch that line three"), "Line one\nline three")
    }

    func testDecimalPointIsNotASentenceBoundary() {
        XCTAssertEqual(ScratchThat.apply(to: "pi is 3.14 scratch that e"), "e")
    }

    func testCommandAtSentenceStartDeletesThePreviousSentence() {
        XCTAssertEqual(ScratchThat.apply(to: "Keep this. Scratch that. And this."), "And this.")
    }

    func testCommandAtEndTrimsTrailingSpace() {
        XCTAssertEqual(ScratchThat.apply(to: "Keep this. Drop this scratch that"), "Keep this.")
        XCTAssertEqual(ScratchThat.apply(to: "Drop everything scratch that"), "")
    }

    func testMultipleOccurrencesInOrder() {
        XCTAssertEqual(ScratchThat.apply(to: "a scratch that b scratch that c"), "c")
        XCTAssertEqual(
            ScratchThat.apply(to: "One. two scratch that three. four scratch that five."), "One. three. five.")
    }

    func testIsCaseInsensitiveAndNeedsWholeWords() {
        XCTAssertEqual(ScratchThat.apply(to: "no SCRATCH THAT yes"), "yes")
        XCTAssertEqual(ScratchThat.apply(to: "scratch thatch stays"), "scratch thatch stays")
    }

    func testTextWithoutCommandIsUnchanged() {
        XCTAssertEqual(ScratchThat.apply(to: "Nothing to do."), "Nothing to do.")
    }

    func testScratchThatOpeningItsOwnSentenceRemovesThePreviousSentence() {
        XCTAssertEqual(
            ScratchThat.apply(to: "Let's send it tomorrow. Scratch that. Send it today."), "Send it today.")
        XCTAssertEqual(
            ScratchThat.apply(to: "Keep this. Drop this one. Scratch that, add this."), "Keep this. add this.")
    }
}

final class FillerRemovalTests: XCTestCase {
    func testRemovesHesitations() {
        XCTAssertEqual(
            FillerRemoval.apply(to: "um so I think we should, uh, send it tomorrow"),
            "so I think we should, send it tomorrow")
        XCTAssertEqual(FillerRemoval.apply(to: "Hmm, maybe"), "maybe")
        XCTAssertEqual(FillerRemoval.apply(to: "well erm yes uhm no"), "well yes no")
        XCTAssertEqual(FillerRemoval.apply(to: "UM, ok"), "ok")
    }

    func testRemovesAttachedTrailingComma() {
        XCTAssertEqual(FillerRemoval.apply(to: "we uh, went home"), "we went home")
    }

    func testCleansDoubledCommasAndPeriodAfterComma() {
        XCTAssertEqual(FillerRemoval.apply(to: "we went, um, home"), "we went, home")
        XCTAssertEqual(FillerRemoval.apply(to: "send it, um."), "send it.")
        XCTAssertEqual(FillerRemoval.apply(to: "send it, um, ."), "send it.")
    }

    func testFillerSubstringsInsideWordsAreKept() {
        XCTAssertEqual(FillerRemoval.apply(to: "the umbrella hummed, humbly"), "the umbrella hummed, humbly")
        XCTAssertEqual(FillerRemoval.apply(to: "uh-huh"), "uh-huh")
    }

    func testRemovesLikeBetweenCommas() {
        XCTAssertEqual(FillerRemoval.apply(to: "it was, like, great"), "it was, great")
    }

    func testRemovesLikeAtSentenceStartBeforeComma() {
        XCTAssertEqual(FillerRemoval.apply(to: "Like, I think so"), "I think so")
        XCTAssertEqual(FillerRemoval.apply(to: "Done. Like, next steps"), "Done. next steps")
        XCTAssertEqual(FillerRemoval.apply(to: "Done\nlike, next"), "Done\nnext")
    }

    func testKeepsLikeWhenNotAFiller() {
        let sentences = [
            "I like it",
            "it looks like rain",
            "like this one",
            "Like this, please",
            "things like, you know",
            "I would like, to go",
            "Do you like cats, like dogs",
            "She is like a sister",
            "Likelihood is high",
        ]
        for sentence in sentences {
            XCTAssertEqual(FillerRemoval.apply(to: sentence), sentence)
        }
    }

    func testUnchangedTextKeepsItsSpacing() {
        XCTAssertEqual(FillerRemoval.apply(to: "keep  this"), "keep  this")
    }
}

final class TextFormattingTests: XCTestCase {
    func testCapitalizesFirstLetterAndSentences() {
        XCTAssertEqual(
            TextFormatting.capitalizeFirst("hello there. how are you? fine! ok"),
            "Hello there. How are you? Fine! Ok")
        XCTAssertEqual(TextFormatting.capitalizeFirst("one\ntwo\n\nthree"), "One\nTwo\n\nThree")
    }

    func testDoesNotCapitalizeInsideNumbersAndFilenames() {
        XCTAssertEqual(TextFormatting.capitalizeFirst("it is 3.5 times. see notes.md now"), "It is 3.5 times. See notes.md now")
    }

    func testLeavesMixedCaseWordsAndLaterLettersAlone() {
        XCTAssertEqual(TextFormatting.capitalizeFirst("iOS is fine. eBay too"), "iOS is fine. eBay too")
    }

    func testSkipsLeadingPunctuationAndDigits() {
        XCTAssertEqual(TextFormatting.capitalizeFirst("\"quoted words\" here"), "\"Quoted words\" here")
        XCTAssertEqual(TextFormatting.capitalizeFirst("3 apples. two pears"), "3 apples. Two pears")
    }

    func testCapitalizeEmpty() {
        XCTAssertEqual(TextFormatting.capitalizeFirst(""), "")
    }

    func testEnsureTerminalPunctuation() {
        XCTAssertEqual(TextFormatting.ensureTerminalPunctuation("hello"), "hello.")
        XCTAssertEqual(TextFormatting.ensureTerminalPunctuation("take 2"), "take 2.")
        XCTAssertEqual(TextFormatting.ensureTerminalPunctuation("hello  \n"), "hello.  \n")
    }

    func testEnsureTerminalPunctuationLeavesExistingEndings() {
        for text in ["hello?", "hello!", "hello.", "hello:", "hello?  ", "(hello)", ""] {
            XCTAssertEqual(TextFormatting.ensureTerminalPunctuation(text), text)
        }
    }
}
