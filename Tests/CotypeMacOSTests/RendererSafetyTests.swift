import XCTest
import CotypeCore
@testable import CotypeMacOS

/// Records every render call so we can assert that `present` only collects and
/// that the controller is the one that renders, post-validation.
private final class SpyRenderer: CompletionRenderer {
    var presented: [String] = []
    var cleared = 0
    func present(_ candidate: String, for request: CompletionRequest) { presented.append(candidate) }
    func clear() { cleared += 1 }
}

// MARK: - CollectingRenderer (no pre-validation render)

final class CollectingRendererTests: XCTestCase {

    func testPresentOnlyCollectsAndNeverRenders() {
        let spy = SpyRenderer()
        let renderer = CollectingRenderer(inner: spy)
        var collected: [String] = []
        renderer.onCandidate = { collected.append($0) }

        // The pipeline calls `present` for every streamed token. It must ONLY
        // collect/callback — the controller renders after validation, never here.
        renderer.present("hel", for: CompletionRequest())
        renderer.present("hello", for: CompletionRequest())

        XCTAssertEqual(collected, ["hel", "hello"])
        XCTAssertTrue(spy.presented.isEmpty, "present must NOT render before validation")
    }

    func testSetGhostRendersAfterValidation() {
        let spy = SpyRenderer()
        let renderer = CollectingRenderer(inner: spy)
        renderer.setGhost("hello")   // controller-driven, post-validation
        XCTAssertEqual(spy.presented, ["hello"])
    }

    func testClearForwardsToInner() {
        let spy = SpyRenderer()
        let renderer = CollectingRenderer(inner: spy)
        renderer.clear()
        XCTAssertEqual(spy.cleared, 1)
    }
}

// MARK: - GhostTextRenderer render-time guard + coalescing

@MainActor
final class GhostTextRendererGuardTests: XCTestCase {

    /// Fixed caret geometry so the renderer can actually display the ghost in the
    /// test environment (no Accessibility lookup) and be observed via `isShowing`.
    private struct FixedGeometry: InlineCaretGeometryProvider {
        let geometry: CaretGeometry?
        func caretGeometry() -> CaretGeometry? { geometry }
    }

    private func makeRenderer() -> GhostTextRenderer {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let metrics = GhostTextMetrics(font: font)
        let geometry = CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
            metrics: metrics
        )
        return GhostTextRenderer(geometryProvider: FixedGeometry(geometry: geometry), maxLines: 3)
    }

    /// Pump the main queue so the coalesced `DispatchQueue.main.async` drain runs.
    private func drain() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testGuardAllowingShowsGhost() async {
        let renderer = makeRenderer()
        renderer.renderGuard = { true }
        renderer.present("abc", for: CompletionRequest())
        await drain()
        XCTAssertTrue(renderer.isShowing, "a guard-allowed draw must appear")
        XCTAssertEqual(renderer.ghostContent.lines.map(\.text), ["abc"])
        renderer.clear()
        await drain()
        XCTAssertFalse(renderer.isShowing)
    }

    /// Inline is the only mode: the overlay is drawn inside the field at the caret
    /// as a transparent, click-through window (never a pane, never focus-stealing).
    /// Editors that expose text + selection but no caret geometry get no overlay
    /// at all — the renderer fails closed and hides.
    func testTrustedCaretGeometryRendersInlineAndClickThrough() async {
        let renderer = makeRenderer()
        renderer.renderGuard = { true }
        renderer.present("abc", for: CompletionRequest())
        await drain()

        XCTAssertTrue(renderer.window.contentView === renderer.ghostContent, "trusted geometry renders the inline ghost")
        XCTAssertTrue(renderer.window.ignoresMouseEvents, "the ghost overlay must stay click-through")
        XCTAssertFalse(renderer.window.isOpaque)
        XCTAssertFalse(renderer.window.hasShadow)
        XCTAssertEqual(renderer.ghostContent.lines.first?.xOffset, 50, "the ghost starts at the caret, not at the field edge")
    }

    /// The inline overlay is caret-anchored: as the streamed ghost grows, the
    /// window tracks its width while the origin (the caret) stays put. A frame
    /// change is therefore only skipped when the frame is genuinely identical.
    func testRepeatedShowKeepsTheCaretAnchoredOriginAndUpdatesContent() async {
        let renderer = makeRenderer()
        renderer.renderGuard = { true }
        renderer.present("ab", for: CompletionRequest())
        await drain()
        let firstFrame = renderer.window.frame
        XCTAssertTrue(renderer.isShowing)

        renderer.present("abc", for: CompletionRequest())
        await drain()
        XCTAssertEqual(renderer.window.frame.origin, firstFrame.origin, "the ghost stays anchored at the caret")
        XCTAssertGreaterThanOrEqual(renderer.window.frame.width, firstFrame.width, "the overlay grows with the ghost text")
        XCTAssertEqual(renderer.ghostContent.lines.map(\.text), ["abc"])
    }

    func testFocusChangeBetweenScheduleAndDrainFailsClosed() async {
        let renderer = makeRenderer()
        // Simulate a focus/generation change AFTER `present` was scheduled but
        // BEFORE the main-queue drain runs.
        renderer.renderGuard = { false }
        renderer.present(" stale ", for: CompletionRequest())
        await drain()
        XCTAssertFalse(renderer.isShowing, "a focus-changed draw must fail closed (orderOut)")
    }

    func testDeniedShowHides() async {
        let renderer = makeRenderer()
        renderer.renderGuard = { false }
        renderer.present("x", for: CompletionRequest())
        await drain()
        XCTAssertFalse(renderer.isShowing, "a denied render must not draw")
    }

    // MARK: - Coalescing race (present/clear/present before drain)

    func testPresentClearPresentBeforeDrainShowsLatest() async {
        let renderer = makeRenderer()
        renderer.renderGuard = { true }
        // present(A) schedules a drain; clear() and present(B) must coalesce to the
        // LATEST action (show B), not leave a stale orderOut that hides B.
        renderer.present("A", for: CompletionRequest())
        renderer.clear()
        renderer.present("B", for: CompletionRequest())
        await drain()
        XCTAssertTrue(renderer.isShowing, "the newest show must win over the interleaved clear")
        XCTAssertEqual(renderer.ghostContent.lines.map(\.text), ["B"])
    }

    func testClearThenPresentShowsLatest() async {
        let renderer = makeRenderer()
        renderer.renderGuard = { true }
        renderer.clear()
        renderer.present("B", for: CompletionRequest())
        await drain()
        XCTAssertTrue(renderer.isShowing)
        XCTAssertEqual(renderer.ghostContent.lines.map(\.text), ["B"])
    }
}
