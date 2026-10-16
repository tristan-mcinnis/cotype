import XCTest
import AppKit
import CotypeCore
@testable import CotypeMacOS

// MARK: - Pure inline-layout geometry

/// Behavioral tests for the approved `InlineGhostLayout` seam. Widths are driven
/// by a deterministic `measure` (10 pt per character) so wrapping and clipping are
/// asserted without relying on real font rasterization.
final class InlineGhostLayoutTests: XCTestCase {

    private let measure: (String) -> CGFloat = { CGFloat($0.count) * 10 }

    // field: x 0..100, tall enough that wrapping does not overflow vertically.
    private let field = CGRect(x: 0, y: 0, width: 100, height: 80)
    private let caret = CGRect(x: 20, y: 5, width: 0, height: 20)
    private let metrics = GhostTextMetrics(
        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    )

    private func layout(
        candidate: String,
        maxLines: Int = 3,
        caret: CGRect? = nil,
        field: CGRect? = nil
    ) -> InlineGhostLayout.Result {
        InlineGhostLayout.layout(
            caretRect: caret ?? self.caret,
            fieldBounds: field ?? self.field,
            metrics: metrics,
            maxLines: maxLines,
            candidate: candidate,
            measure: measure
        )
    }

    func testSingleLineCandidateStartsAtCaretAndDoesNotWrap() {
        let result = layout(candidate: "hello") // 5 chars = 50pt

        XCTAssertEqual(result.wasClipped, false)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines.first?.text, "hello")
        // Indented to the caret (caretX 20 - fieldMinX 0).
        XCTAssertEqual(result.lines.first?.xOffset, 20)
        // Block left edge = field leading edge; top = caret line top.
        XCTAssertEqual(result.origin, NSPoint(x: 0, y: 5))
        // Width = caret indent + text width, clamped to the field.
        XCTAssertEqual(result.size.width, 20 + 50)
        XCTAssertEqual(result.size.height, metrics.lineHeight)
    }

    func testLongCandidateWrapsToFieldLeadingEdgeOnNextLine() {
        // Line 1 has only 60pt from the caret (x=40 -> fieldMaxX=100).
        let curCaret = CGRect(x: 40, y: 5, width: 0, height: 20)
        let result = layout(candidate: "hello world", caret: curCaret)

        XCTAssertEqual(result.wasClipped, false)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "hello")   // "hello"=50 <= 60
        XCTAssertEqual(result.lines[0].xOffset, 40)     // caret indent
        XCTAssertEqual(result.lines[1].text, "world")   // wraps to field leading edge
        XCTAssertEqual(result.lines[1].xOffset, 0)
        XCTAssertEqual(result.origin, NSPoint(x: 0, y: 5))
        // Width = furthest line extent (caret indent 40 + "hello" 50), no clamp.
        XCTAssertEqual(result.size.width, 40 + 50)
        XCTAssertEqual(result.size.height, 2 * metrics.lineHeight)
    }

    func testExceedingMaxLinesClipsAndSignals() {
        // Line 1 has 60pt; "one two three four five six" needs 3 lines.
        let curCaret = CGRect(x: 40, y: 5, width: 0, height: 20)
        let result = layout(candidate: "one two three four five six", maxLines: 2, caret: curCaret)

        XCTAssertEqual(result.wasClipped, true)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "one")
        XCTAssertEqual(result.lines[0].xOffset, 40)
        XCTAssertEqual(result.lines[1].text, "two three…")
    }

    func testEmptyCandidateProducesNoLines() {
        let result = layout(candidate: "")
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertFalse(result.wasClipped)
    }

    func testCaretAtFieldEdgeClampsWidthToField() {
        // Caret sits exactly at the field's right edge: line 1 has 0 available, so
        // the single word is placed but the block width stays within the field.
        let edgeCaret = CGRect(x: 100, y: 5, width: 0, height: 20)
        let result = layout(candidate: "x", caret: edgeCaret)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines.first?.xOffset, 100)
        XCTAssertEqual(result.size.width, 100)
    }

    func testNegativeFieldWidthNeverYieldsNegativeBlock() {
        let degenerate = CGRect(x: 0, y: 0, width: -40, height: 30)
        let result = layout(candidate: "hello", field: degenerate)
        XCTAssertGreaterThanOrEqual(result.size.width, 0)
    }

    func testShortFieldClipsGhostVerticallyToField() {
        // Only 20pt of vertical space below the caret line, but the candidate
        // needs two lines: the block height is clamped and flagged as clipped.
        let shortField = CGRect(x: 0, y: 0, width: 100, height: 25)
        let curCaret = CGRect(x: 40, y: 5, width: 0, height: 20)
        let result = layout(candidate: "hello world", caret: curCaret, field: shortField)

        XCTAssertEqual(result.wasClipped, true)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.size.height, max(25 - 5, metrics.lineHeight))
    }

    func testLeadingSpacesArePreservedOnFirstLine() {
        let result = layout(candidate: "  hello") // two leading spaces

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines.first?.text, "  hello")
        XCTAssertEqual(result.lines.first?.xOffset, 20)
        // Width includes the preserved indentation (2 spaces + 5 chars).
        XCTAssertEqual(result.size.width, 20 + 70)
    }

    func testExplicitNewlineIsAHardBreakEvenWhenItFitsOnOneLine() {
        // Wide field: "hello world" alone would fit on one line, but the newline
        // must force a second line.
        let wide = CGRect(x: 0, y: 0, width: 200, height: 80)
        let result = layout(candidate: "hello\nworld", caret: caret, field: wide)

        XCTAssertEqual(result.wasClipped, false)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "hello")
        XCTAssertEqual(result.lines[1].text, "world")
        // After a hard break the next line starts at the field's leading edge.
        XCTAssertEqual(result.lines[1].xOffset, 0)
    }

    func testIndentationAfterNewlineIsPreservedVerbatim() {
        let wide = CGRect(x: 0, y: 0, width: 200, height: 80)
        let result = layout(candidate: "  hello\n    world", caret: caret, field: wide)

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "  hello")
        XCTAssertEqual(result.lines[0].xOffset, 20)
        XCTAssertEqual(result.lines[1].text, "    world")
        XCTAssertEqual(result.lines[1].xOffset, 0)
    }
}

// MARK: - Font metrics

final class GhostTextMetricsTests: XCTestCase {
    func testLineHeightIsAtLeastCapHeightAndNonZero() {
        let metrics = GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        XCTAssertGreaterThan(metrics.lineHeight, 0)
        XCTAssertGreaterThanOrEqual(metrics.lineHeight, 12)
        XCTAssertGreaterThan(metrics.ascent, 0)
        XCTAssertGreaterThan(metrics.descent, 0)
    }

    func testDefaultMetricsAreStableAndReusable() {
        let a = GhostTextMetrics.default
        let b = GhostTextMetrics.default
        XCTAssertEqual(a.lineHeight, b.lineHeight)
        XCTAssertEqual(a.font.pointSize, 13)
    }
}

// MARK: - AX-to-AppKit coordinate conversion

final class CaretPlacementConversionTests: XCTestCase {
    func testFlippedTopLeftOriginRoundTripsAcrossPrimaryHeight() {
        // AX top-left (y-down) at (50, 200), window 100x20, primary height 900.
        let origin = CaretPlacement.toAppKitWindowOrigin(
            axTopLeft: NSPoint(x: 50, y: 200),
            size: NSSize(width: 100, height: 20),
            primaryScreenHeight: 900
        )
        XCTAssertEqual(origin.x, 50)
        XCTAssertEqual(origin.y, 900 - 200 - 20)
    }

    func testWindowAtVeryTopOfScreenMapsToPrimaryHeightMinusHeight() {
        let origin = CaretPlacement.toAppKitWindowOrigin(
            axTopLeft: NSPoint(x: 0, y: 0),
            size: NSSize(width: 100, height: 30),
            primaryScreenHeight: 800
        )
        XCTAssertEqual(origin.y, 800 - 30)
    }
}

// MARK: - AX kAXBoundsForRange decode (must be a CGRect, not a point)

final class AXBoundsDecodingTests: XCTestCase {
    func testDecodesBoundsForRangeAsCGRect() {
        var rect = CGRect(x: 100, y: 200, width: 10, height: 20)
        guard let axValue = AXValueCreate(.cgRect, &rect) else {
            return XCTFail("could not create a CGRect AXValue")
        }
        XCTAssertEqual(AXCaretGeometryProvider.decodeCGRect(from: axValue), rect)
    }

    func testRejectsAPointValueInsteadOfMisDecodingARect() {
        // The old buggy decoder read AXValue as .cgPoint. A point must never be
        // accepted where a CGRect is expected, otherwise the bounds are garbage.
        var point = CGPoint(x: 100, y: 200)
        guard let axValue = AXValueCreate(.cgPoint, &point) else {
            return XCTFail("could not create a point AXValue")
        }
        XCTAssertNil(AXCaretGeometryProvider.decodeCGRect(from: axValue))
    }
}

final class AXCaretGeometryValidationTests: XCTestCase {
    func testRejectsChatGPTWindowEdgeZeroHeightCaret() {
        let editor = CGRect(x: 28, y: 882, width: 448, height: 44)
        let bogusCaret = CGRect(x: 0, y: 982, width: 0, height: 0)
        XCTAssertFalse(AXCaretGeometryProvider.isUsableCaretRect(bogusCaret, inside: editor))
    }

    func testAcceptsRealCaretInsideEditor() {
        let editor = CGRect(x: 28, y: 882, width: 448, height: 44)
        let caret = CGRect(x: 120, y: 891, width: 0, height: 17)
        XCTAssertTrue(AXCaretGeometryProvider.isUsableCaretRect(caret, inside: editor))
    }

    /// End of a full line: a zero-width insertion caret sits exactly on the
    /// field's trailing edge. `CGRect.intersects` is false for a zero-area rect
    /// and `CGRect.contains` is half-open on `maxX`, so the gate must accept this
    /// edge explicitly or the ghost disappears at end-of-line.
    func testAcceptsZeroWidthCaretExactlyAtFieldTrailingEdge() {
        let editor = CGRect(x: 28, y: 882, width: 448, height: 44)
        let caret = CGRect(x: editor.maxX, y: 891, width: 0, height: 17)
        XCTAssertTrue(
            AXCaretGeometryProvider.isUsableCaretRect(caret, inside: editor),
            "a zero-width caret on the field's trailing edge is a real insertion point"
        )
    }

    func testRejectsCaretPastFieldTrailingEdge() {
        let editor = CGRect(x: 28, y: 882, width: 448, height: 44)
        let caret = CGRect(x: editor.maxX + 5, y: 891, width: 0, height: 17)
        XCTAssertFalse(
            AXCaretGeometryProvider.isUsableCaretRect(caret, inside: editor),
            "geometry past the field's trailing edge is out of bounds"
        )
    }

    func testRejectsCaretBelowFieldBottom() {
        let editor = CGRect(x: 28, y: 882, width: 448, height: 44)
        let caret = CGRect(x: editor.minX + 10, y: editor.maxY + 5, width: 0, height: 17)
        XCTAssertFalse(
            AXCaretGeometryProvider.isUsableCaretRect(caret, inside: editor),
            "geometry below the field's bottom edge is out of bounds"
        )
    }
}

// MARK: - AX font-probe range selection (pure)

final class FontProbeRangeTests: XCTestCase {
    func testProbesCharacterImmediatelyBeforeCaret() {
        let range = AXCaretGeometryProvider.fontProbeRange(
            for: CFRange(location: 5, length: 0),
            documentLength: 10
        )
        XCTAssertEqual(range.location, 4)
        XCTAssertEqual(range.length, 1)
    }

    func testProbesAfterCaretAtDocumentStart() {
        let range = AXCaretGeometryProvider.fontProbeRange(
            for: CFRange(location: 0, length: 0),
            documentLength: 10
        )
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 1)
    }

    func testProbesLastCharacterWhenCaretAtDocumentEnd() {
        let range = AXCaretGeometryProvider.fontProbeRange(
            for: CFRange(location: 10, length: 0),
            documentLength: 10
        )
        XCTAssertEqual(range.location, 9)
        XCTAssertEqual(range.length, 1)
    }

    func testEmptyDocumentYieldsEmptyProbeSoRendererFallsBack() {
        let range = AXCaretGeometryProvider.fontProbeRange(
            for: CFRange(location: 0, length: 0),
            documentLength: 0
        )
        XCTAssertEqual(range.length, 0)
    }

    func testCaretSitsOnTrailingEdgeOfTheCharacterBeforeIt() {
        XCTAssertEqual(
            AXCaretGeometryProvider.caretEdge(forCaretRange: CFRange(location: 5, length: 0)),
            .trailing
        )
    }

    func testCaretSitsOnLeadingEdgeAtDocumentStart() {
        // Nothing precedes the caret, so the probe is the character after it and
        // the caret must not be placed beyond that character.
        XCTAssertEqual(
            AXCaretGeometryProvider.caretEdge(forCaretRange: CFRange(location: 0, length: 0)),
            .leading
        )
    }

    func testCaretSitsOnTrailingEdgeOfASelectionsAnchor() {
        XCTAssertEqual(
            AXCaretGeometryProvider.caretEdge(forCaretRange: CFRange(location: 7, length: 3)),
            .trailing
        )
    }
}

// MARK: - AX caret-rect strategy ladder (pure)

final class AXCaretLadderTests: XCTestCase {

    // A real editor: the caret line sits inside it with room around it.
    private let field = CGRect(x: 28, y: 882, width: 448, height: 44)
    private let selectedRangeRect = CGRect(x: 120, y: 891, width: 0, height: 17)
    private let precedingCharacterRect = CGRect(x: 120, y: 891, width: 1, height: 17)
    private let markerRangeRect = CGRect(x: 121, y: 891, width: 0, height: 17)

    /// The Electron/Chromium failure: a zero-height rect at the window edge.
    private let bogusRect = CGRect(x: 0, y: 982, width: 0, height: 0)

    func testPrefersSelectedRangeBoundsAndNeverEvaluatesLaterStrategies() {
        var evaluated: [CaretRectStrategy] = []
        let result = AXCaretGeometryProvider.firstUsableCaret(inside: field, [
            (.selectedRangeBounds, { evaluated.append(.selectedRangeBounds); return self.selectedRangeRect }),
            (.precedingCharacterBounds, { evaluated.append(.precedingCharacterBounds); return self.precedingCharacterRect }),
            (.textMarkerRangeBounds, { evaluated.append(.textMarkerRangeBounds); return self.markerRangeRect }),
        ])

        XCTAssertEqual(result?.strategy, .selectedRangeBounds)
        XCTAssertEqual(result?.rect, selectedRangeRect)
        // Laziness is part of the contract: later strategies are AX round trips.
        XCTAssertEqual(evaluated, [.selectedRangeBounds])
    }

    func testFallsThroughToPrecedingCharacterWhenSelectedRangeIsImplausible() {
        var evaluated: [CaretRectStrategy] = []
        let result = AXCaretGeometryProvider.firstUsableCaret(inside: field, [
            (.selectedRangeBounds, { evaluated.append(.selectedRangeBounds); return self.bogusRect }),
            (.precedingCharacterBounds, { evaluated.append(.precedingCharacterBounds); return self.precedingCharacterRect }),
            (.textMarkerRangeBounds, { evaluated.append(.textMarkerRangeBounds); return self.markerRangeRect }),
        ])

        XCTAssertEqual(result?.strategy, .precedingCharacterBounds)
        XCTAssertEqual(result?.rect, precedingCharacterRect)
        XCTAssertEqual(evaluated, [.selectedRangeBounds, .precedingCharacterBounds])
    }

    func testFallsThroughToTextMarkerRangeWhenBothRangeStrategiesFail() {
        var evaluated: [CaretRectStrategy] = []
        let result = AXCaretGeometryProvider.firstUsableCaret(inside: field, [
            (.selectedRangeBounds, { evaluated.append(.selectedRangeBounds); return nil }),
            (.precedingCharacterBounds, { evaluated.append(.precedingCharacterBounds); return self.bogusRect }),
            (.textMarkerRangeBounds, { evaluated.append(.textMarkerRangeBounds); return self.markerRangeRect }),
        ])

        XCTAssertEqual(result?.strategy, .textMarkerRangeBounds)
        XCTAssertEqual(result?.rect, markerRangeRect)
        XCTAssertEqual(evaluated, [.selectedRangeBounds, .precedingCharacterBounds, .textMarkerRangeBounds])
    }

    func testFailsClosedWhenEveryStrategyIsImplausible() {
        // Ghostty-shaped input: the editor answers every route with nothing
        // usable. The ladder must return nil so the renderer hides; it must never
        // pick the least-bad rect.
        let result = AXCaretGeometryProvider.firstUsableCaret(inside: field, [
            (.selectedRangeBounds, { nil }),
            (.precedingCharacterBounds, { self.bogusRect }),
            (.textMarkerRangeBounds, { CGRect(x: self.field.maxX + 40, y: 891, width: 0, height: 17) }),
        ])
        XCTAssertNil(result)
    }

    func testFailsClosedWhenFieldBoundsAreDegenerate() {
        var evaluated = 0
        let result = AXCaretGeometryProvider.firstUsableCaret(
            inside: CGRect(x: 0, y: 0, width: 0, height: 0),
            [(.selectedRangeBounds, { evaluated += 1; return self.selectedRangeRect })]
        )
        XCTAssertNil(result)
        XCTAssertEqual(evaluated, 1, "the candidate is still produced; the gate is what rejects it")
    }

    /// The declared order is the order the provider tries them, so a future
    /// reorder of the enum is a visible failure rather than a silent behavior change.
    func testStrategyOrderIsTheDocumentedLadder() {
        XCTAssertEqual(
            CaretRectStrategy.allCases,
            [.selectedRangeBounds, .precedingCharacterBounds, .textMarkerRangeBounds]
        )
    }
}

// MARK: - Character bounds to 1 pt caret conversion (pure)

final class CaretRectFromCharacterBoundsTests: XCTestCase {

    private let character = CGRect(x: 100, y: 891, width: 9, height: 17)

    func testTrailingEdgeCaretSitsAtCharacterMaxX() {
        let caret = AXCaretGeometryProvider.caretRect(fromCharacterBounds: character, at: .trailing)
        XCTAssertEqual(caret, CGRect(x: 109, y: 891, width: 1, height: 17))
        XCTAssertEqual(caret?.minX, character.maxX)
    }

    func testLeadingEdgeCaretSitsAtCharacterMinX() {
        let caret = AXCaretGeometryProvider.caretRect(fromCharacterBounds: character, at: .leading)
        XCTAssertEqual(caret, CGRect(x: 100, y: 891, width: 1, height: 17))
    }

    func testConvertedCaretSurvivesTheFieldBoundsGate() {
        let field = CGRect(x: 28, y: 882, width: 448, height: 44)
        guard let caret = AXCaretGeometryProvider.caretRect(fromCharacterBounds: character, at: .trailing) else {
            return XCTFail("a real character rect must convert to a caret")
        }
        XCTAssertTrue(AXCaretGeometryProvider.isUsableCaretRect(caret, inside: field))
    }

    /// End of a full line: the preceding character's trailing edge is exactly the
    /// field's trailing edge, which a zero-area `intersects` test would reject.
    func testConvertedCaretAtTheFieldsTrailingEdgeIsAccepted() {
        let field = CGRect(x: 28, y: 882, width: 448, height: 44)
        let lastCharacter = CGRect(x: field.maxX - 9, y: 891, width: 9, height: 17)
        guard let caret = AXCaretGeometryProvider.caretRect(fromCharacterBounds: lastCharacter, at: .trailing) else {
            return XCTFail("a real character rect must convert to a caret")
        }
        XCTAssertEqual(caret.minX, field.maxX)
        XCTAssertTrue(AXCaretGeometryProvider.isUsableCaretRect(caret, inside: field))
    }

    func testZeroHeightCharacterBoundsYieldNoCaret() {
        let degenerate = CGRect(x: 100, y: 982, width: 9, height: 0)
        XCTAssertNil(AXCaretGeometryProvider.caretRect(fromCharacterBounds: degenerate, at: .trailing))
    }

    func testNegativeWidthCharacterBoundsUseTheTrueTrailingEdge() {
        // CoreGraphics keeps a raw negative width but still reports the true right
        // edge, so an unnormalized character rect still yields the right caret.
        let unnormalized = CGRect(x: 100, y: 891, width: -9, height: 17)
        XCTAssertEqual(
            AXCaretGeometryProvider.caretRect(fromCharacterBounds: unnormalized, at: .trailing),
            AXCaretGeometryProvider.caretRect(fromCharacterBounds: unnormalized.standardized, at: .trailing)
        )
    }

    /// The 1 pt caret this step builds is one point thick, so sitting on the
    /// field's trailing edge puts its leading edge exactly on that edge and its
    /// own thickness just past it. That is still the insertion point at the end
    /// of a full line, so the ladder's gate accepts it.
    func testOnePointCaretAnchoredOnTheFieldTrailingEdgeIsAccepted() {
        let field = CGRect(x: 28, y: 882, width: 448, height: 44)
        XCTAssertTrue(
            AXCaretGeometryProvider.isUsableCaretRect(
                CGRect(x: field.maxX, y: 891, width: 1, height: 17),
                inside: field
            )
        )
    }

    func testOnePointCaretAnchoredPastTheFieldTrailingEdgeIsRejected() {
        let field = CGRect(x: 28, y: 882, width: 448, height: 44)
        XCTAssertFalse(
            AXCaretGeometryProvider.isUsableCaretRect(
                CGRect(x: field.maxX + 2, y: 891, width: 1, height: 17),
                inside: field
            )
        )
    }
}

// MARK: - CompletionRenderer seam (inline ghost)

final class GhostTextRendererTests: XCTestCase {

    private struct FixedGeometry: InlineCaretGeometryProvider {
        let geometry: CaretGeometry?
        func caretGeometry() -> CaretGeometry? { geometry }
    }

    func testShowsInlineGhostAtCaretWhenGeometryResolves() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let metrics = GhostTextMetrics(font: font)
        let geometry = CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
            metrics: metrics
        )
        let renderer = GhostTextRenderer(
            geometryProvider: FixedGeometry(geometry: geometry),
            maxLines: 3
        )
        renderer.show(candidate: "hello")

        // The candidate is laid out as one inline line indented to the caret.
        XCTAssertEqual(renderer.ghostContent.lines.map(\.text), ["hello"])
        XCTAssertEqual(renderer.ghostContent.lines.first?.xOffset, 50) // caretX - fieldMinX

        // Window is sized to the resolved ghost block, not a fixed 360x72 box.
        let expectedWidth = min(
            50 + ("hello" as NSString).size(withAttributes: [.font: font]).width,
            400
        )
        XCTAssertEqual(renderer.window.frame.origin.x, 50)
        XCTAssertEqual(renderer.window.frame.width, expectedWidth, accuracy: 1)
        XCTAssertEqual(renderer.window.frame.height, metrics.lineHeight, accuracy: 1)
    }

    func testDoesNotFallBackToMouseWhenGeometryUnavailable() {
        // No caret geometry: the renderer must NOT anchor to the mouse, must NOT
        // show a pane, and must NOT guess a field frame. It fails closed and hides.
        let renderer = GhostTextRenderer(
            geometryProvider: FixedGeometry(geometry: nil),
            maxLines: 3
        )
        renderer.show(candidate: "hello")

        // No caret geometry: no inline lines and the window is left hidden at the
        // origin, never repositioned to the mouse cursor or to a panel.
        XCTAssertTrue(renderer.ghostContent.lines.isEmpty)
        XCTAssertEqual(renderer.window.frame.origin, .zero)
        XCTAssertFalse(renderer.window.isVisible)
    }

    func testEmptyCandidateWithGeometryStillHides() {
        // An empty candidate must never leave a stale ghost or an empty box behind.
        let metrics = GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        let renderer = GhostTextRenderer(
            geometryProvider: FixedGeometry(
                geometry: CaretGeometry(
                    caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
                    fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
                    metrics: metrics
                )
            ),
            maxLines: 3
        )
        renderer.show(candidate: "")
        XCTAssertFalse(renderer.window.isVisible)
    }

    func testWindowIsTransparentNonActivatingAndMouseIgnoring() {
        let renderer = GhostTextRenderer(
            geometryProvider: FixedGeometry(geometry: nil),
            maxLines: 3
        )
        let window = renderer.window
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.hasShadow)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(window.level, .floating)
    }
}
