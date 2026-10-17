import AppKit
import XCTest
import CotypeCore
@testable import CotypeMacOS

/// Real (in-process) AppKit editors: what the inserted text does to the
/// document, the undo stack, typing attributes and selection. No private text is
/// read from any other app; every string here is synthetic.
@MainActor
final class EditorCompatibilityTests: XCTestCase {

    /// A plain-text editor in a window, so AppKit provides a real undo manager.
    private func makePlainEditor(_ text: String) -> (NSTextView, NSWindow) {
        // AppKit needs an initialized application for a window + undo manager in
        // a test bundle.
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        window.contentView = editor
        return (editor, window)
    }

    private func makeRichEditor(_ text: String) -> (NSTextView, NSWindow) {
        let (editor, window) = makePlainEditor(text)
        editor.isRichText = true
        return (editor, window)
    }

    private func insertAtCaret(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    // MARK: Undo

    func testOneUndoRemovesTheWholeAcceptedSegment() {
        let (editor, window) = makePlainEditor("Dear ")
        _ = window
        XCTAssertNotNil(editor.undoManager)

        insertAtCaret("Sam,", into: editor)
        XCTAssertEqual(editor.string, "Dear Sam,")

        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "Dear ", "one undo must remove the whole inserted segment")
    }

    func testTwoAcceptedSegmentsAreTwoUndoableActions() async throws {
        let (editor, window) = makePlainEditor("See you ")
        _ = window
        let clipboard = EditorClipboard(editor: editor)
        let inserter = PasteboardInserter(
            restoreDelayNanoseconds: 1,
            clipboard: clipboard,
            preflightPostEventAccess: { true }
        )

        try await inserter.insert("at ", appIdentifier: nil)
        // Let AppKit close the undo group between accepts, as a real run-loop
        // turn (and the user's next Tab) does.
        try? await Task.sleep(nanoseconds: 60_000_000)
        editor.breakUndoCoalescing()
        try await inserter.insert("the office", appIdentifier: nil)
        XCTAssertEqual(editor.string, "See you at the office")

        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "See you at ", "each accepted segment is its own undo step")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "See you ")
    }

    /// The production insertion path (pasteboard write -> posted paste ->
    /// restore) against a real editor. The fake clipboard performs the paste by
    /// calling the editor's own insertText, which is what Cmd+V ends in.
    func testPasteInsertionIsOneUndoableActionAndLeavesTheCaretAfterIt() async throws {
        let (editor, window) = makePlainEditor("Thanks ")
        _ = window
        let clipboard = EditorClipboard(editor: editor)
        let inserter = PasteboardInserter(
            restoreDelayNanoseconds: 1,
            clipboard: clipboard,
            preflightPostEventAccess: { true }
        )

        try await inserter.insert("for the update", appIdentifier: nil)
        XCTAssertEqual(editor.string, "Thanks for the update")
        XCTAssertEqual(editor.selectedRange().location, ("Thanks for the update" as NSString).length)
        XCTAssertEqual(clipboard.restoreCalls, 1, "the user's clipboard is restored after the paste")

        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "Thanks ")
    }

    // MARK: Rich text and attributes

    func testInsertionPreservesTypingAttributesAndSurroundingFormatting() {
        let (editor, window) = makeRichEditor("Bold lead in. ")
        _ = window
        let bold = NSFont.boldSystemFont(ofSize: 14)
        let body = NSFont.systemFont(ofSize: 13)
        editor.textStorage?.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
        editor.typingAttributes = [.font: body, .foregroundColor: NSColor.systemBlue]

        insertAtCaret("Next sentence.", into: editor)

        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont), body)
        XCTAssertEqual((editor.typingAttributes[.foregroundColor] as? NSColor), NSColor.systemBlue)
        let boldRange = NSRange(location: 0, length: 5)
        XCTAssertEqual((editor.textStorage?.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont), bold)
        // The inserted text took the editor's typing attributes, not a new style.
        let insertedStart = ("Bold lead in. " as NSString).length
        XCTAssertEqual((editor.textStorage?.attribute(.font, at: insertedStart, effectiveRange: nil) as? NSFont), body)
    }

    func testReplacingASelectionLeavesTextAfterItIntact() {
        let (editor, window) = makePlainEditor("Hello world")
        _ = window
        // Select "world" and accept a completion over it.
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        insertAtCaret("there", into: editor)
        XCTAssertEqual(editor.string, "Hello there")
    }

    // MARK: CJK and spacing

    func testCJKInsertionAddsNoSynthesizedSpace() {
        let (editor, window) = makePlainEditor("我们周一")
        _ = window
        insertAtCaret("开会讨论", into: editor)
        XCTAssertEqual(editor.string, "我们周一开会讨论")
        XCTAssertFalse(editor.string.contains(" "))
    }

    func testInsertionAfterOneSpaceKeepsExactlyOneSpace() {
        let (editor, window) = makePlainEditor("Let me get back to you by ")
        _ = window
        insertAtCaret("the end", into: editor)
        XCTAssertEqual(editor.string, "Let me get back to you by the end")
        XCTAssertFalse(editor.string.contains("  "))
    }
}

/// A clipboard operator that performs the paste on a real NSTextView. It stands
/// in for the Cmd+V that production posts, so the editor's own undo and
/// attribute handling are exercised.
@MainActor
private final class EditorClipboard: ClipboardOperator, @unchecked Sendable {
    private let editor: NSTextView
    private var pending: String?
    private var changeCount = 0
    private(set) var restoreCalls = 0

    init(editor: NSTextView) {
        self.editor = editor
    }

    func snapshot() -> ClipboardSnapshot {
        ClipboardSnapshot(items: [], changeCount: changeCount)
    }

    func writeForPaste(_ text: String) -> Int? {
        pending = text
        changeCount += 1
        return changeCount
    }

    func postPaste() {
        guard let text = pending else { return }
        pending = nil
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func restore(_ snapshot: ClipboardSnapshot, expectedChangeCount: Int?, ignoreChangeCount: Bool) -> Bool {
        restoreCalls += 1
        return true
    }
}
