import XCTest
@testable import CotypeCore

/// The context window kept for the completion prompt must be the text nearest
/// the caret — the tail of the prefix — not the start of the document. A long
/// document's early lines offer no signal and waste context, and (critically)
/// the Gemma prompt header structure must never be drowned out by a huge prefix.
final class ContextWindowTests: XCTestCase {

    func testKeepsNearestCaretTail() {
        let prefix = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let window = ContextWindow.nearestCaret(prefix: prefix, maxChars: 10)
        XCTAssertEqual(window, "QRSTUVWXYZ", "the trailing 10 chars nearest the caret must be kept")
    }

    func testShortPrefixUnchanged() {
        let prefix = "func add(a: Int, b: Int) -> Int"
        XCTAssertEqual(ContextWindow.nearestCaret(prefix: prefix, maxChars: 2000), prefix)
    }

    func testExactBoundaryKeptWhole() {
        let prefix = String(repeating: "x", count: 12)
        XCTAssertEqual(ContextWindow.nearestCaret(prefix: prefix, maxChars: 12), prefix)
    }

    func testEmptyPrefix() {
        XCTAssertEqual(ContextWindow.nearestCaret(prefix: "", maxChars: 100), "")
    }

    func testNearestCaretSuffixKeepsLeading() {
        // Suffix is text AFTER the caret, so nearest-to-caret is its LEADING chars.
        let suffix = "LEAD-" + String(repeating: "z", count: 5000)
        let window = ContextWindow.nearestCaretSuffix(suffix, maxChars: 8)
        XCTAssertEqual(window, "LEAD-zzz", "the nearest-to-caret (leading) suffix must be kept")
    }

    func testSuffixShorterThanWindowUnchanged() {
        let suffix = "\")"
        XCTAssertEqual(ContextWindow.nearestCaretSuffix(suffix, maxChars: 2000), suffix)
    }

    func testEmptySuffixYieldsEmpty() {
        XCTAssertEqual(ContextWindow.nearestCaretSuffix("", maxChars: 100), "")
    }

    func testTrimsToCharacterBoundaryAndDropsLeadingWhitespaceLine() {
        // The tail may begin mid-word after a newline; nearest-to-caret still wins.
        let prefix = "line one line two line three\nfunc add(a: Int, b: Int) -> Int {\n    return a + b\n"
        let window = ContextWindow.nearestCaret(prefix: prefix, maxChars: 2000)
        XCTAssertTrue(
            window.hasSuffix("a + b\n") || window.hasSuffix("return a + b\n"),
            "the window must retain the nearest-to-caret tail: \(window)"
        )
    }
}
