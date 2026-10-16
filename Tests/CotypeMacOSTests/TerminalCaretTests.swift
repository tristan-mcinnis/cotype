import XCTest
@testable import CotypeMacOS

@MainActor
final class TerminalCaretTests: XCTestCase {
    private let screen = "Last login: today\n~ % ls\nfoo bar\n> please review the dec\n\n"

    func testFindsCaretAfterLastTypedOccurrence() {
        let offset = TerminalCaret.caretOffset(in: screen, typed: "review the dec")
        XCTAssertEqual(offset, (screen as NSString).range(of: "the dec").upperBound)
        let pos = TerminalCaret.gridPosition(of: offset!, in: screen)
        XCTAssertEqual(pos.row, 3)
        XCTAssertEqual(pos.column, "> please review the dec".count)
    }

    func testTooShortOrMissingFailsClosed() {
        XCTAssertNil(TerminalCaret.caretOffset(in: screen, typed: "de"))
        XCTAssertNil(TerminalCaret.caretOffset(in: screen, typed: "zzzzzz"))
    }

    func testCaretRectFromGrid() {
        let wide = String(repeating: "─", count: 100)
        let grid = [wide, "> hi there", "", ""].joined(separator: "\n")
        let field = CGRect(x: 0, y: 0, width: 800, height: 80)
        let rect = TerminalCaret.caretRect(row: 1, column: 10, field: field, screen: grid)
        XCTAssertEqual(rect?.minX ?? -1, 80, accuracy: 0.01)   // 800 / 100 per cell
        XCTAssertEqual(rect?.minY ?? -1, 20, accuracy: 0.01)   // 80 / 4 rows
        XCTAssertEqual(rect?.height ?? -1, 20, accuracy: 0.01)
    }
}
