import XCTest
@testable import CotypeCore

final class HeuristicPatternTests: XCTestCase {

    func testFactsAreCalledForWhereADetailComesNext() {
        for text in [
            "My name is ", "Hi all, this is ", "this is ", "You can reach me at ",
            "I work at ", "I\u{2019}m with ", "I'm based in ", "I'm the ", "I\u{2019}m the Managing Partner at ",
            "Thanks for the call.\n\nBest,\n", "Kind regards,", "我叫",
        ] {
            XCTAssertTrue(AuthorFacts.areCalledFor(afterText: text), text)
        }
    }

    func testFactsAreNotCalledForInOrdinarySentences() {
        for text in [
            "I'm the one who broke the build, sorry about", "this is the best",
            "I think this is", "Sounds good, all the best", "My name is Sam.\nCan you send the deck",
            "I'm the first to admit it",
        ] {
            XCTAssertFalse(AuthorFacts.areCalledFor(afterText: text), text)
        }
    }

    func testProseWithCodeLikePunctuationIsProse() {
        for text in [
            "I went home; she stayed at the office and", "plan: research -> synthesis -> deck, then we",
            "so 3 groups x 8 = 24 people, which", "let me know if that works\nlet me know",
            "# Notes\nthe client liked it", "public holiday on monday so", "class is at 3 today and",
            "import duties went up again, so",
        ] {
            XCTAssertFalse(TextKind.looksLikeCode(text), text)
        }
    }

    func testCodeIsStillCode() {
        for text in [
            "func load() {", "let total = items.count", "if a == b", "print(value", "x += 1",
            "import Foundation\n", "def main():", "    return value", "for i in range(3);\n",
            "```swift\nlet", "<div>", "func f() -> Int", "#include <stdio.h>", "const x = 3",
            "private func reset", "export const y",
        ] {
            XCTAssertTrue(TextKind.looksLikeCode(text), text)
        }
    }

    func testAPhraseAboutContextInASentenceIsKept() {
        let text = " it depends on the budget, depending on the context of"
        XCTAssertEqual(ModelTalk.removed(from: text), text)
    }

    func testAStreamingLinkIsHeldBackUntilItIsComplete() {
        XCTAssertEqual(ModelTalk.removed(from: " see [the full"), " see")
        XCTAssertEqual(ModelTalk.removed(from: " see [the full notes]"), " see")
        XCTAssertEqual(ModelTalk.removed(from: " see [the full notes](https://x.example)"), " see [the full notes](https://x.example)")
    }

    func testEmojiEndTheSuggestionWhenTheyAreOff() {
        XCTAssertEqual(CompletionPipeline.finalize(" sounds good 👍", prefix: "ok ", maxWords: 4, allowsEmoji: false), " sounds good")
        XCTAssertEqual(CompletionPipeline.finalize(" love it ❤️ see", prefix: "I ", maxWords: 4, allowsEmoji: false), " love it")
        XCTAssertEqual(CompletionPipeline.finalize("😂", prefix: "lol ", maxWords: 4, allowsEmoji: false), "")
        XCTAssertEqual(CompletionPipeline.finalize(" sounds good 👍", prefix: "ok ", maxWords: 4, allowsEmoji: true), " sounds good 👍")
        XCTAssertTrue(CompletionPipeline.isFixed(" sounds good 👍", prefix: "ok ", maxWords: 4, allowsEmoji: false))
    }

    func testDigitsAndSymbolsAreNotEmoji() {
        let text = " room 3 #2 © 2026 ™ * note → next"
        XCTAssertEqual(EmojiFilter.cutAtFirstEmoji(text), text)
        XCTAssertEqual(EmojiFilter.cutAtFirstEmoji(" press 1️⃣ now"), " press")
        XCTAssertEqual(EmojiFilter.cutAtFirstEmoji(" team 👩‍💻 done"), " team")
    }

    func testEmojiAreOffByDefault() {
        let defaults = makeUserDefaults()
        XCTAssertFalse(EmojiFilter.allowsEmoji(defaults))
    }
}
