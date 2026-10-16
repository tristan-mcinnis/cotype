import XCTest
@testable import CotypeMacOS

final class ActiveWindowContextCompactorTests: XCTestCase {
    func testNormalizesDeduplicatesAndPreservesReadingOrder() {
        XCTAssertEqual(
            ActiveWindowContextCompactor.compact(
                ["  Earlier   message ", "Latest reply", "Earlier message"],
                maxChars: 200
            ),
            "Earlier message\nLatest reply"
        )
    }

    func testKeepsMostRecentTailWithinBound() {
        let result = ActiveWindowContextCompactor.compact(
            ["old context that should be dropped", "recent message remains"],
            maxChars: 24
        )
        XCTAssertTrue(result.contains("recent message remains"))
        XCTAssertLessThanOrEqual(result.count, 24)
    }

    func testEmptyAndZeroBoundProduceNoContext() {
        XCTAssertEqual(ActiveWindowContextCompactor.compact([], maxChars: 100), "")
        XCTAssertEqual(ActiveWindowContextCompactor.compact(["hello"], maxChars: 0), "")
    }

    /// The active-window tree walk is a second Accessibility traversal, so it is
    /// off by default and its budgets stay small when it is enabled.
    @MainActor
    func testProviderShipsWithTheWindowTreeWalkOff() {
        XCTAssertFalse(AXTextContextProvider().includeWindowContext)
    }

    @MainActor
    func testCollectorBudgetsStayBounded() {
        let collector = AXActiveWindowContextCollector()
        XCTAssertLessThanOrEqual(collector.maxChars, 1_000)
        XCTAssertLessThanOrEqual(collector.maxNodes, 500)
        XCTAssertLessThanOrEqual(collector.maxDepth, 20)
    }
}
