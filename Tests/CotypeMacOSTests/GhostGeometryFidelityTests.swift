import XCTest
import AppKit
@testable import CotypeMacOS

// MARK: - Font metrics and baseline (measured against AppKit's own typesetter)

/// The ghost used to draw with a `ceil`-built line box and a baseline taken from
/// `NSFont.ascender`. Both differ from where the editor's own text sits: for
/// Helvetica 12 the typesetter uses a 14 pt box and puts the baseline at 11 pt,
/// while the ghost was 2 pt low. These tests read the same numbers out of AppKit
/// and require the metrics to agree with them.
final class GhostTextMetricsFidelityTests: XCTestCase {

    /// The baseline AppKit's typesetter actually uses for a one-line fragment.
    private func typesetterBaseline(_ font: NSFont) -> CGFloat {
        let storage = NSTextStorage(string: "Hg")
        storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: 2))
        let container = NSTextContainer(size: NSSize(width: 300, height: 100))
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return manager.location(forGlyphAt: 0).y
    }

    func testLineBoxIsAppKitsDefaultLineHeight() {
        for font in EditorFonts.samples {
            let metrics = GhostTextMetrics(font: font)
            XCTAssertEqual(
                metrics.lineHeight,
                NSLayoutManager().defaultLineHeight(for: font),
                accuracy: 0.001,
                "line box must be AppKit's own for \(font.fontName) \(font.pointSize)"
            )
            XCTAssertEqual(metrics.ascent + metrics.descent + metrics.leading, metrics.lineHeight, accuracy: 0.001)
        }
    }

    func testBaselineMatchesTheTypesetterForProportionalAndMonospacedFaces() {
        for font in EditorFonts.samples {
            let metrics = GhostTextMetrics(font: font)
            XCTAssertEqual(
                metrics.baselineOffset,
                typesetterBaseline(font),
                accuracy: 0.001,
                "baseline must land where the typesetter puts it for \(font.fontName) \(font.pointSize)"
            )
        }
    }

    /// The old `ceil(ascender) + ceil(descent) + leading` box was one to four
    /// points taller than the document's, which is what produced the measured
    /// 18 pt pitch against a 14 pt document.
    func testHelveticaTwelveUsesTheDocumentsLineBoxAndBaseline() {
        guard let helvetica = NSFont(name: "Helvetica", size: 12) else {
            return XCTFail("Helvetica 12 must exist on macOS")
        }
        let metrics = GhostTextMetrics(font: helvetica)
        XCTAssertEqual(metrics.lineHeight, 14, accuracy: 0.001)
        XCTAssertEqual(metrics.baselineOffset, 11, accuracy: 0.001)
    }

    // MARK: - Fitting the editor's own line box

    func testMeasuredEditorLineBoxMovesBaselineAndPitch() {
        let mono = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertEqual(mono.lineHeight, 16, accuracy: 0.001)

        // TextEdit's caret is 14 pt tall for 12 pt Helvetica text.
        let fitted = mono.aligningLineBox(toMeasuredHeight: 14)
        XCTAssertEqual(fitted.lineHeight, 14, accuracy: 0.001)
        XCTAssertEqual(fitted.baselineOffset, 11, accuracy: 0.001)
        // The font is unchanged: only the line box was re-measured.
        XCTAssertEqual(fitted.font.pointSize, 13)
    }

    func testTallerEditorLineBoxKeepsTheFontBaseline() {
        // Double-spaced text: AppKit adds the extra space below the line, so the
        // baseline must not move down with the box.
        let metrics = GhostTextMetrics(font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12))
        let fitted = metrics.aligningLineBox(toMeasuredHeight: 20)
        XCTAssertEqual(fitted.lineHeight, 20, accuracy: 0.001)
        XCTAssertEqual(fitted.baselineOffset, 11, accuracy: 0.001)
    }

    func testImplausibleMeasuredLineBoxesAreRejected() {
        let metrics = GhostTextMetrics(font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12))
        // A selection spanning three lines, an empty/garbage rect, and a box far
        // too short to be a line: all keep the font's own metrics.
        for height in [42, 0, -14, CGFloat.nan, CGFloat.infinity, 5] as [CGFloat] {
            XCTAssertEqual(metrics.aligningLineBox(toMeasuredHeight: height), metrics, "height \(height)")
        }
    }

    func testDrawingOffsetPlacesTheBaselineAtTheResolvedOffset() {
        let mono = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let fitted = mono.aligningLineBox(toMeasuredHeight: 14)

        // `NSString.draw(at:)` puts the baseline one descent above the bottom of
        // the font's own box; the draw offset cancels the difference, so the
        // rendered baseline lands on the resolved one.
        let drawBaseline = NSLayoutManager().defaultLineHeight(for: mono.font) - mono.descent
        XCTAssertEqual(drawBaseline + mono.baselineDrawOffset, mono.baselineOffset, accuracy: 0.001)
        XCTAssertEqual(drawBaseline + fitted.baselineDrawOffset, fitted.baselineOffset, accuracy: 0.001)
        XCTAssertEqual(fitted.baselineDrawOffset, -2, accuracy: 0.5, "the measured 2 pt error comes out")
    }

    // MARK: - Fallback faces

    func testDefaultFallbackIsProportionalWhileTerminalMetricsStayMonospaced() {
        // An unknown editor font is far more likely to be a UI text face than a
        // code face; a monospaced ghost was measured at 1.7x the document width.
        XCTAssertFalse(GhostTextMetrics.default.font.isFixedPitch, "the unknown-font fallback must not be monospaced")

        // Terminals draw on a character grid and keep their own monospaced metrics.
        let terminal = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        XCTAssertTrue(terminal.font.isFixedPitch)
        XCTAssertEqual(GhostTextMetrics.default.font.pointSize, 13)
    }
}

/// Fonts an editor can realistically be set in, on the current system.
private enum EditorFonts {
    static var samples: [NSFont] {
        [
            NSFont(name: "Helvetica", size: 12),
            NSFont(name: "Helvetica", size: 18),
            NSFont(name: "Menlo", size: 12),
            NSFont(name: "Menlo", size: 14),
            NSFont(name: "Lucida Grande", size: 13),
            NSFont.systemFont(ofSize: 13),
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ].compactMap { $0 }
    }
}

// MARK: - Text-column inset resolution (pure decision)

final class TextColumnInsetTests: XCTestCase {

    // A text view whose frame starts at x=100 but whose text column starts at 105.
    private let field = CGRect(x: 100, y: 200, width: 400, height: 200)
    private let caret = CGRect(x: 205, y: 210, width: 1, height: 14)

    private func inset(
        first: CGRect,
        last: CGRect? = CGRect(x: 300, y: 210, width: 6, height: 14),
        caret: CGRect? = nil
    ) -> CGFloat? {
        AXCaretGeometryProvider.textColumnInset(
            firstCharacter: first,
            lastCharacter: last,
            caretRect: caret ?? self.caret,
            fieldBounds: field
        )
    }

    func testMeasuresTheLineColumnsLeftMargin() {
        // TextEdit-style: a 5 pt container inset inside the text view's frame.
        XCTAssertEqual(inset(first: CGRect(x: 105, y: 210, width: 7, height: 14)), 5)
    }

    func testZeroInsetForAFieldWhoseTextStartsAtItsEdge() {
        XCTAssertNil(inset(first: CGRect(x: 100, y: 210, width: 7, height: 14)), "a 0 pt inset needs no shift")
    }

    func testRightToLeftLineIsRejected() {
        // On an RTL line the logical first character is the rightmost one; a left
        // inset there would push the continuation into the middle of the text.
        let first = CGRect(x: 400, y: 210, width: 7, height: 14)
        let last = CGRect(x: 180, y: 210, width: 7, height: 14)
        let rightCaret = CGRect(x: 399, y: 210, width: 1, height: 14)
        XCTAssertNil(inset(first: first, last: last, caret: rightCaret))
    }

    func testFirstCharacterOnAnotherLineIsRejected() {
        // A stale line range: the first character sits two lines above the caret.
        XCTAssertNil(inset(first: CGRect(x: 105, y: 182, width: 7, height: 14)))
    }

    func testFirstCharacterLeftOfTheFieldIsRejected() {
        // Scrolled or centered geometry: the character is outside the field.
        XCTAssertNil(inset(first: CGRect(x: 60, y: 210, width: 7, height: 14)))
    }

    func testCaretLeftOfTheColumnIsRejected() {
        // A caret left of its line's first character cannot belong to that column.
        let leftCaret = CGRect(x: 90, y: 210, width: 1, height: 14)
        XCTAssertNil(inset(first: CGRect(x: 105, y: 210, width: 7, height: 14), caret: leftCaret))
    }

    func testAnOversizedMarginIsRejected() {
        // 40 % of the field is a mis-read column, not a margin.
        XCTAssertNil(inset(first: CGRect(x: 260, y: 210, width: 7, height: 14)))
    }

    /// A line ending in a newline often reports empty bounds for its last
    /// character, so direction cannot be confirmed. A narrow margin is still
    /// accepted; a wide one is not guessed.
    func testUnconfirmedDirectionAcceptsOnlyANarrowMargin() {
        XCTAssertEqual(inset(first: CGRect(x: 105, y: 210, width: 7, height: 14), last: nil), 5)
        XCTAssertEqual(inset(first: CGRect(x: 105, y: 210, width: 7, height: 14), last: CGRect(x: 105, y: 210, width: 0, height: 0)), 5)
        // 120 pt of a 400 pt field (30 %) needs confirmed left-to-right bounds.
        let indentedCaret = CGRect(x: 235, y: 210, width: 1, height: 14)
        XCTAssertNil(inset(first: CGRect(x: 220, y: 210, width: 7, height: 14), last: nil, caret: indentedCaret))
        XCTAssertEqual(
            inset(
                first: CGRect(x: 220, y: 210, width: 7, height: 14),
                last: CGRect(x: 380, y: 210, width: 6, height: 14),
                caret: indentedCaret
            ),
            120
        )
    }

    func testDegenerateGeometryIsRejected() {
        XCTAssertNil(inset(first: CGRect(x: 105, y: 210, width: 7, height: 0)))
        XCTAssertNil(
            AXCaretGeometryProvider.textColumnInset(
                firstCharacter: CGRect(x: 105, y: 210, width: 7, height: 14),
                lastCharacter: nil,
                caretRect: caret,
                fieldBounds: CGRect(x: 100, y: 200, width: 0, height: 200)
            )
        )
        XCTAssertNil(
            AXCaretGeometryProvider.textColumnInset(
                firstCharacter: CGRect(x: 105, y: 210, width: 7, height: 14),
                lastCharacter: nil,
                caretRect: caret,
                fieldBounds: CGRect(x: 100, y: 200, width: 400, height: 0)
            )
        )
    }

    func testNonFiniteCoordinatesAreRejected() {
        XCTAssertNil(inset(first: CGRect(x: CGFloat.nan, y: 210, width: 7, height: 14)))
        XCTAssertNil(inset(first: CGRect(x: 105, y: 210, width: CGFloat.infinity, height: 14)))
    }
}

// MARK: - Wrapping through the measured text column

final class InlineGhostLayoutInsetTests: XCTestCase {

    private let measure: (String) -> CGFloat = { CGFloat($0.count) * 10 }
    private let field = CGRect(x: 0, y: 0, width: 100, height: 80)
    private let caret = CGRect(x: 60, y: 5, width: 0, height: 20)
    private let metrics = GhostTextMetrics(
        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    )

    private func layout(
        candidate: String,
        inset: CGFloat,
        maxLines: Int = 3,
        field: CGRect? = nil,
        caret: CGRect? = nil
    ) -> InlineGhostLayout.Result {
        InlineGhostLayout.layout(
            caretRect: caret ?? self.caret,
            fieldBounds: field ?? self.field,
            metrics: metrics,
            maxLines: maxLines,
            textInset: inset,
            candidate: candidate,
            measure: measure
        )
    }

    func testWrappedLineStartsAtTheMeasuredInset() {
        let result = layout(candidate: "hello world", inset: 8)

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "hello")
        XCTAssertEqual(result.lines[0].xOffset, 60, "the caret line still starts at the caret")
        XCTAssertEqual(result.lines[1].text, "world")
        XCTAssertEqual(result.lines[1].xOffset, 8, "the wrapped line starts at the text column")
        XCTAssertEqual(result.origin, NSPoint(x: 0, y: 5), "the window still starts at the field edge")
    }

    func testHardBreakStartsAtTheMeasuredInset() {
        let result = layout(candidate: "hello\nworld", inset: 12, field: CGRect(x: 0, y: 0, width: 400, height: 80))
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[1].xOffset, 12)
    }

    func testInsetNarrowsTheWrappedLineAvailableWidth() {
        // Field is 100 wide; a 30 pt inset leaves 70 pt for wrapped lines, so a
        // 9-character (90 pt) word wraps again instead of running to the edge.
        let wide = CGRect(x: 0, y: 0, width: 100, height: 80)
        let word = "aaaaaaaaa" // 90 pt
        let inserted = layout(candidate: "hi \(word)", inset: 30, field: wide)

        XCTAssertEqual(inserted.lines[0].text, "hi")
        XCTAssertEqual(inserted.lines[1].text, word, "one long word is still placed on its own line")
        XCTAssertEqual(inserted.lines.count, 2)

        // Two shorter words: 40 + 40 fits on a wrapped line without the inset, but
        // not with it (70 available), so they split.
        let split = layout(candidate: "hi \(String(repeating: "b", count: 4)) \(String(repeating: "c", count: 4))", inset: 30, field: wide)
        XCTAssertEqual(split.lines.count, 3)
        XCTAssertEqual(split.lines[1].text, "bbbb")
        XCTAssertEqual(split.lines[1].xOffset, 30)
        XCTAssertEqual(split.lines[2].text, "cccc")
    }

    func testInsetZeroIsTheUnchangedFieldEdgeBehaviour() {
        // The existing layout contracts stay: no measured column, no shift.
        let result = layout(candidate: "hello world", inset: 0)
        XCTAssertEqual(result.lines[1].xOffset, 0)
        XCTAssertEqual(result.origin, NSPoint(x: 0, y: 5))
    }

    func testInsetNeverPushesTheBlockOutsideTheField() {
        let result = layout(candidate: "hello world hello", inset: 50)
        XCTAssertLessThanOrEqual(result.size.width, field.width)
        XCTAssertEqual(result.origin.x, field.minX)
        // Wrapped lines respect the column and the field's trailing edge. (The
        // caret line starts at the caret, which is inside the field by definition.)
        for line in result.lines.dropFirst() {
            XCTAssertGreaterThanOrEqual(line.xOffset, 0)
            XCTAssertLessThanOrEqual(line.xOffset + measure(line.text), field.width, line.text)
        }
    }

    func testClippedBlockStillFitsTheFieldWindow() {
        // A clipped block appends an ellipsis after its last line, so the line can
        // be wider than the column; the overlay window is still the field's width,
        // which is what keeps the ghost on screen inside the field.
        let result = layout(candidate: "hello world hello world hello", inset: 50)
        XCTAssertTrue(result.wasClipped)
        XCTAssertLessThanOrEqual(result.size.width, field.width)
        XCTAssertEqual(result.origin.x, field.minX)
    }

    func testImplausibleInsetsFallBackToTheFieldEdge() {
        // Negative, non-finite, and wider-than-field values are not margins.
        for inset in [-5, CGFloat.nan, 400] as [CGFloat] {
            let result = layout(candidate: "hello world", inset: inset)
            XCTAssertEqual(result.lines[1].xOffset, 0, "inset \(inset)")
        }
    }

    func testHalfFieldCapKeepsRoomForTheGhostText() {
        // A 90 pt inset on a 100 pt field would leave 10 pt: capped at half.
        let result = layout(candidate: "hello world", inset: 90)
        XCTAssertEqual(result.lines[1].xOffset, 50)
        XCTAssertLessThanOrEqual(result.size.width, field.width)
    }

    func testVerticalClippingStillHoldsWithAnInset() {
        let shortField = CGRect(x: 0, y: 0, width: 100, height: 25)
        let result = layout(candidate: "hello world", inset: 8, field: shortField)
        XCTAssertTrue(result.wasClipped)
        XCTAssertEqual(result.size.height, max(25 - 5, metrics.lineHeight))
    }

    func testMaxLinesClippingStillHoldsWithAnInset() {
        let result = layout(candidate: "one two three four five six", inset: 8, maxLines: 2)
        XCTAssertTrue(result.wasClipped)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[1].xOffset, 8)
        XCTAssertTrue(result.lines[1].text.hasSuffix("…"))
    }
}

// MARK: - Renderer pass-through

@MainActor
final class GhostTextRendererInsetTests: XCTestCase {

    private struct FixedGeometry: InlineCaretGeometryProvider {
        let geometry: CaretGeometry?
        func caretGeometry() -> CaretGeometry? { geometry }
    }

    private func geometry(inset: CGFloat, caretHeight: CGFloat = 20) -> CaretGeometry {
        CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: caretHeight),
            fieldBounds: CGRect(x: 50, y: 150, width: 300, height: 200),
            metrics: GhostTextMetrics(font: .monospacedSystemFont(ofSize: 12, weight: .regular)),
            textInset: inset
        )
    }

    func testRendererWrapsAtTheGeometryInsetInsideTheField() {
        let renderer = GhostTextRenderer(
            geometryProvider: FixedGeometry(geometry: geometry(inset: 12)),
            maxLines: 3
        )
        renderer.show(candidate: String(repeating: "word ", count: 30))

        XCTAssertGreaterThan(renderer.ghostContent.lines.count, 1, "the long candidate must wrap")
        XCTAssertEqual(renderer.ghostContent.lines[1].xOffset, 12)
        XCTAssertEqual(renderer.window.frame.origin.x, 50, "the overlay still starts at the field edge")
        XCTAssertLessThanOrEqual(renderer.window.frame.width, 300)
        renderer.window.orderOut(nil)
    }

    func testRendererPlacesTheGhostBaselineFromTheResolvedMetrics() {
        let mono = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let fitted = mono.aligningLineBox(toMeasuredHeight: 14)
        XCTAssertEqual(fitted.baselineOffset, 11, accuracy: 0.001)

        let renderer = GhostTextRenderer(
            geometryProvider: FixedGeometry(
                geometry: CaretGeometry(
                    caretRect: CGRect(x: 100, y: 200, width: 0, height: 14),
                    fieldBounds: CGRect(x: 50, y: 150, width: 300, height: 200),
                    metrics: fitted
                )
            ),
            maxLines: 3
        )
        renderer.show(candidate: "hello")
        XCTAssertEqual(renderer.window.frame.height, 14, accuracy: 0.001)
        XCTAssertEqual(renderer.ghostContent.metrics.baselineOffset, 11, accuracy: 0.001)
        renderer.window.orderOut(nil)
    }

    func testFallbackPreviewKeepsTheFieldEdge() {
        // The anchored fallback has no caret line to measure, so it must never pick
        // up a column inset.
        let metrics = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        struct FieldOnly: InlineCaretGeometryProvider, InlineFieldGeometryProvider {
            let field: CaretFieldGeometry
            func caretGeometry() -> CaretGeometry? { nil }
            func fieldGeometry() -> CaretFieldGeometry? { field }
        }
        let field = FieldOnly(
            field: CaretFieldGeometry(fieldBounds: CGRect(x: 50, y: 150, width: 300, height: 200), metrics: metrics)
        )
        let renderer = GhostTextRenderer(geometryProvider: field, maxLines: 1, fallbackEnabled: { true })
        renderer.show(candidate: "hello world")

        XCTAssertTrue(renderer.isFallbackPreview)
        XCTAssertEqual(renderer.ghostContent.lines.first?.xOffset, 2, "the fallback anchors 2 pt inside the field")
        XCTAssertEqual(renderer.window.frame.origin.x, 50)
        renderer.window.orderOut(nil)
    }
}

// MARK: - Rendered baseline (pixels, not arithmetic)

@MainActor
final class GhostBaselineDrawTests: XCTestCase {

    private let size = NSSize(width: 200, height: 60)
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func inkTopRow(metrics: GhostTextMetrics) -> Int? {
        let view = GhostContentView(frame: NSRect(origin: .zero, size: size))
        view.metrics = metrics
        view.lines = [("H", 0)]
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                return y
            }
        }
        return nil
    }

    func testFittingTheEditorLineBoxRaisesTheDrawnBaseline() throws {
        let unaligned = GhostTextMetrics(font: font)
        let aligned = unaligned.aligningLineBox(toMeasuredHeight: 14)
        // The baseline moves from 13 to 11 inside the box.
        XCTAssertEqual(unaligned.baselineOffset, 13, accuracy: 0.001)
        XCTAssertEqual(aligned.baselineOffset, 11, accuracy: 0.001)

        let plain = try XCTUnwrap(inkTopRow(metrics: unaligned), "the ghost must draw ink")
        let fitted = try XCTUnwrap(inkTopRow(metrics: aligned), "the ghost must draw ink")
        XCTAssertEqual(
            abs(plain - fitted),
            2,
            "the glyphs must move up by the 2 pt the old baseline was low (plain \(plain), fitted \(fitted))"
        )
    }
}
