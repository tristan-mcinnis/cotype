import XCTest
@testable import CotypeCore

final class CaretBoundaryTests: XCTestCase {
    private let words: Set<String> = ["by", "the", "questions", "any", "weekend", "hope", "great", "deck", "fine"]
    private func isWord(_ w: String) -> Bool { words.contains(w.lowercased()) }

    func testAddsMissingSpaceAfterCompleteWord() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "back to you by", candidate: "the end", isWord: isWord), " the end")
    }

    func testStripsRestatedPartialWord() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "any questi", candidate: "questions or concerns", isWord: isWord), "ons or concerns")
    }

    func testJoinsMidWordContinuation() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "a great weeke", candidate: "nd and more", isWord: isWord), "nd and more")
    }

    func testDropsLeadingSpaceAfterTypedSpace() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "by ", candidate: " the end", isWord: isWord), "the end")
    }

    func testKeepsModelSpaceWhenGiven() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "by", candidate: " the end", isWord: isWord), " the end")
    }

    func testAddsSpaceAfterPunctuation() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "Thanks,", candidate: "see you", isWord: isWord), " see you")
    }

    func testPunctuationContinuationStaysAttached() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "yes", candidate: ", I will", isWord: isWord), ", I will")
    }

    func testNeverSpacesCJK() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "这个项目的主要目标是", candidate: "开发一个新系统", isWord: isWord), "开发一个新系统")
    }

    func testStripsScaffoldEcho() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "by ", candidate: "Output: the end", isWord: isWord), "the end")
    }

    func testWithoutOracleLeavesAmbiguousJoinAlone() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "by", candidate: "the end"), "the end")
    }
}

final class AppCompatibilityTests: XCTestCase {
    func testTerminalsOffByDefaultButOverridable() {
        XCTAssertFalse(AppCompatibility.isEnabled(bundleID: "com.mitchellh.ghostty", override: nil))
        XCTAssertTrue(AppCompatibility.isEnabled(bundleID: "com.mitchellh.ghostty", override: true))
        XCTAssertTrue(AppCompatibility.isEnabled(bundleID: "com.apple.TextEdit", override: nil))
        XCTAssertFalse(AppCompatibility.isEnabled(bundleID: "com.apple.TextEdit", override: false))
    }

    func testChromiumNeedsWake() {
        XCTAssertTrue(AppCompatibility.needsWebAccessibilityWake(bundleID: "net.imput.helium", bundleURL: nil))
        XCTAssertFalse(AppCompatibility.needsWebAccessibilityWake(bundleID: "com.apple.TextEdit", bundleURL: nil))
    }
}

final class PersonalFactsPromptTests: XCTestCase {
    func testFactsAppendAsBulletsAndEmptyIsNoOp() {
        XCTAssertEqual(AutocompletePrompt.withPersonalFacts("SYS", facts: "  \n"), "SYS")
        let out = AutocompletePrompt.withPersonalFacts("SYS", facts: "Work email: a@example.com\n\nName: A {{prefix}}")
        XCTAssertTrue(out.hasPrefix("SYS\n\nAbout the author"))
        XCTAssertTrue(out.contains("- Work email: a@example.com\n- Name: A { {prefix}}"))
    }
}

final class SuggestionLengthTests: XCTestCase {
    func testLengthDrivesPromptAndCaps() {
        XCTAssertTrue(SuggestionLength.long.applied(to: AutocompletePrompt.defaultSystem).contains("finish the current sentence"))
        XCTAssertFalse(SuggestionLength.short.applied(to: AutocompletePrompt.defaultSystem).contains("2-5 words"))
        XCTAssertEqual(SuggestionWordLimiter.limit("due to better quality and price", maxWords: SuggestionLength.short.maxWords), "due to better")
        let d = UserDefaults(suiteName: "SuggestionLengthTests")!
        d.removePersistentDomain(forName: "SuggestionLengthTests")
        XCTAssertEqual(SuggestionLength.current(d), .medium)
    }

    func testHiGetsASpace() {
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "hi", candidate: "there", isWord: { ["hi", "there"].contains($0) }), " there")
    }
}
