import AppKit
import XCTest
import CotypeCore
@testable import CotypeMacOS

/// The acceptance invariant: text is inserted only while its preview is on
/// screen. These tests drive the production renderer with geometry that cannot
/// place a caret, so a pending candidate exists while nothing is visible.
@MainActor
final class VisiblePreviewAcceptanceTests: XCTestCase {

    private static let stableFocus = FocusTarget(
        appIdentifier: "com.example.editor",
        windowIdentity: 1,
        elementIdentity: 2,
        selection: .unsupported
    )

    private struct NoGeometry: InlineCaretGeometryProvider {
        func caretGeometry() -> CaretGeometry? { nil }
    }

    private struct TinyField: InlineCaretGeometryProvider, InlineFieldGeometryProvider {
        func caretGeometry() -> CaretGeometry? { nil }
        func fieldGeometry() -> CaretFieldGeometry? {
            CaretFieldGeometry(
                fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 8),
                metrics: GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            )
        }
    }

    private struct NoCaretWithField: InlineCaretGeometryProvider, InlineFieldGeometryProvider {
        func caretGeometry() -> CaretGeometry? { nil }
        func fieldGeometry() -> CaretFieldGeometry? {
            CaretFieldGeometry(
                fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
                metrics: GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            )
        }
    }

    private func makeController(
        renderer: CompletionRenderer,
        power: PowerState = .externalPower
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let inserter = RecordingInserter()
        let controller = CompletionController(
            engineManager: EngineManager(
                modelPathOverride: "/fake/model.gguf",
                engineFactory: { _ in MockClosableEngine() }
            ),
            personalization: makePersonalizationStore(),
            overrides: AppOverridesStore(fileURL: tempFileURL("overrides")),
            websiteRules: makeWebsiteRulesStore(),
            powerStateProvider: FixedPowerState(power),
            inserter: inserter,
            renderer: renderer,
            pipelineEngineOverride: MockInferenceEngine(response: "hello there", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(Self.stableFocus),
            userDefaults: defaults
        )
        controller.debounceInterval = 0.02
        controller.cooldownInterval = 0.02
        return (controller, inserter)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testAcceptDoesNothingWhenThePreviewCannotBeDrawn() async {
        let renderer = GhostTextRenderer(geometryProvider: NoGeometry(), fallbackEnabled: { false })
        let (controller, inserter) = makeController(renderer: renderer)

        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        // The candidate exists, but no ghost reached the screen.
        XCTAssertEqual(controller.currentCandidate, "hello there")
        XCTAssertFalse(controller.isGhostVisible)
        XCTAssertFalse(controller.isAcceptKeyReady)

        controller.accept()
        controller.acceptNextWord()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(inserter.inserted.isEmpty, "an unseen preview must never insert")
        XCTAssertTrue(controller.hasPendingCompletion, "the refused accept leaves the candidate alone")
    }

    func testGeometricallyVisiblePreviewStillAccepts() async {
        struct Fixed: InlineCaretGeometryProvider {
            func caretGeometry() -> CaretGeometry? {
                CaretGeometry(
                    caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
                    fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200)
                )
            }
        }
        let renderer = GhostTextRenderer(geometryProvider: Fixed())
        let (controller, inserter) = makeController(renderer: renderer)

        XCTAssertTrue(controller.trigger())
        let visible = await waitUntil { controller.isAcceptKeyReady }
        XCTAssertTrue(visible, "the ghost must be on screen before accept is offered")
        controller.accept()
        let inserted = await waitUntil { !inserter.inserted.isEmpty }
        XCTAssertTrue(inserted)
        XCTAssertEqual(inserter.inserted, ["hello there"])
    }

    // MARK: Opt-in anchored fallback

    func testFallbackPreviewIsOffByDefaultAndReportsWhy() async {
        let renderer = GhostTextRenderer(geometryProvider: NoCaretWithField(), fallbackEnabled: { false })
        var reasons: [NotShownReason] = []
        renderer.onNotShown = { reasons.append($0) }
        renderer.renderGuard = { true }
        renderer.present("hello", for: CompletionRequest())
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(renderer.isShowing)
        XCTAssertEqual(reasons, [.noCaretGeometry])
    }

    func testFallbackPreviewIsAnchoredInertAndStillAcceptableWhenOptedIn() async {
        let renderer = GhostTextRenderer(geometryProvider: NoCaretWithField(), fallbackEnabled: { true })
        renderer.renderGuard = { true }
        renderer.present("hello", for: CompletionRequest())
        let shown = await waitUntil { renderer.isShowing }
        XCTAssertTrue(shown)
        XCTAssertTrue(renderer.isFallbackPreview)
        XCTAssertTrue(renderer.window.ignoresMouseEvents, "the fallback preview stays non-interactive")
        // Inside the focused field's x-range, one line tall: anchored to the
        // field, not to the mouse and not a detached pane.
        XCTAssertGreaterThanOrEqual(renderer.window.frame.minX, 50)
        XCTAssertLessThanOrEqual(renderer.window.frame.maxX, 450)
        XCTAssertLessThanOrEqual(renderer.window.frame.height, 40)
        XCTAssertEqual(renderer.ghostContent.lines.count, 1)
        // Convert the AppKit frame back to AX top-left space and require it to
        // sit inside the focused field's real bounds.
        if let screenHeight = NSScreen.screens.first?.frame.height {
            let axTop = screenHeight - renderer.window.frame.maxY
            let axBottom = axTop + renderer.window.frame.height
            XCTAssertGreaterThanOrEqual(axTop, 150)
            XCTAssertLessThanOrEqual(axBottom, 350)
        }
    }

    /// A field too short to contain one line fails closed instead of drawing the
    /// ghost above the field.
    func testFallbackPreviewHidesWhenTheFieldCannotContainALine() async {
        let renderer = GhostTextRenderer(geometryProvider: TinyField(), fallbackEnabled: { true })
        var reasons: [NotShownReason] = []
        renderer.onNotShown = { reasons.append($0) }
        renderer.renderGuard = { true }
        renderer.present("hello", for: CompletionRequest())
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(renderer.isShowing)
        XCTAssertFalse(renderer.isFallbackPreview)
        XCTAssertEqual(reasons, [.ghostDoesNotFit])
    }

    func testFallbackPreviewAcceptsOnlyBecauseItIsVisible() async {
        let renderer = GhostTextRenderer(geometryProvider: NoCaretWithField(), fallbackEnabled: { true })
        let (controller, inserter) = makeController(renderer: renderer)

        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.isAcceptKeyReady }
        XCTAssertTrue(ready, "an opt-in fallback is a visible preview, so accept is offered")
        controller.accept()
        let inserted = await waitUntil { !inserter.inserted.isEmpty }
        XCTAssertTrue(inserted)
        XCTAssertEqual(inserter.inserted, ["hello there"])
    }
}

/// A power state that never reads the real battery.
struct FixedPowerState: PowerStateProviding {
    let state: PowerState

    init(_ state: PowerState) { self.state = state }

    func current() -> PowerState { state }
}
