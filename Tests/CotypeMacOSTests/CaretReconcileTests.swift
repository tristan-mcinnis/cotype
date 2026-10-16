import XCTest
@testable import CotypeMacOS

final class CaretReconcileTests: XCTestCase {
    private let anchor = CGRect(x: 100, y: 50, width: 1, height: 16)

    func testZeroLengthWinsWhenItAgreesWithAnchor() {
        let zero = CGRect(x: 102, y: 51, width: 0, height: 16)
        let chosen = AXCaretGeometryProvider.reconcileCaret(zeroLength: zero, anchor: anchor, isWebContent: false)
        XCTAssertEqual(chosen?.strategy, .selectedRangeBounds)
    }

    func testWideGapZeroLengthLosesToAnchor() {
        let zero = CGRect(x: 300, y: 50, width: 0, height: 16)
        let chosen = AXCaretGeometryProvider.reconcileCaret(zeroLength: zero, anchor: anchor, isWebContent: false)
        XCTAssertEqual(chosen?.strategy, .precedingCharacterBounds)
        XCTAssertEqual(chosen?.rect, anchor)
    }

    func testWebContentPrefersAnchor() {
        let zero = CGRect(x: 101, y: 50, width: 0, height: 16)
        let chosen = AXCaretGeometryProvider.reconcileCaret(zeroLength: zero, anchor: anchor, isWebContent: true)
        XCTAssertEqual(chosen?.strategy, .precedingCharacterBounds)
    }

    func testSingleSourceAndNone() {
        XCTAssertEqual(AXCaretGeometryProvider.reconcileCaret(zeroLength: nil, anchor: anchor, isWebContent: false)?.rect, anchor)
        XCTAssertNil(AXCaretGeometryProvider.reconcileCaret(zeroLength: nil, anchor: nil, isWebContent: false))
    }

    func testRejectsLineBoxSizedCaret() {
        let field = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(AXCaretGeometryProvider.isUsableCaretRect(CGRect(x: 10, y: 10, width: 1, height: 400), inside: field))
        XCTAssertFalse(AXCaretGeometryProvider.isUsableCaretRect(CGRect(x: 10, y: 10, width: 1, height: 1), inside: field))
        XCTAssertTrue(AXCaretGeometryProvider.isUsableCaretRect(CGRect(x: 10, y: 10, width: 1, height: 16), inside: field))
    }
}
