import XCTest
@testable import CotypeCore

final class SuggestionWordLimiterTests: XCTestCase {
    func testLeavesOneToFourWordsUnchanged() {
        XCTAssertEqual(SuggestionWordLimiter.limit("one"), "one")
        XCTAssertEqual(SuggestionWordLimiter.limit("one two three four"), "one two three four")
    }

    func testCutsBeforeFifthWordAndDropsSeparator() {
        XCTAssertEqual(
            SuggestionWordLimiter.limit("one two three four five six"),
            "one two three four"
        )
    }

    func testPreservesLeadingBoundaryAndAttachedPunctuation() {
        XCTAssertEqual(
            SuggestionWordLimiter.limit(" next few words, please continue"),
            " next few words, please"
        )
    }

    func testCountsCodeUnitsByWhitespace() {
        XCTAssertEqual(SuggestionWordLimiter.limit("a + b * c"), "a + b *")
    }

    func testZeroLimitAndEmptyInputReturnEmpty() {
        XCTAssertEqual(SuggestionWordLimiter.limit("hello", maxWords: 0), "")
        XCTAssertEqual(SuggestionWordLimiter.limit(""), "")
    }
}
