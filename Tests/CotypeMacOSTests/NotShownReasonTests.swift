import XCTest
import CotypeCore
@testable import CotypeMacOS

@MainActor
final class NotShownReasonTests: XCTestCase {

    private static let editor = "com.example.editor"
    private static let focus = FocusTarget(
        appIdentifier: editor, windowIdentity: 1, elementIdentity: 2, selection: .unsupported
    )
    private static let movedFocus = FocusTarget(
        appIdentifier: editor, windowIdentity: 1, elementIdentity: 999, selection: .unsupported
    )

    private struct FixedGeometry: InlineCaretGeometryProvider {
        var field = CGRect(x: 50, y: 150, width: 400, height: 200)
        func caretGeometry() -> CaretGeometry? {
            CaretGeometry(caretRect: CGRect(x: 100, y: 200, width: 0, height: 20), fieldBounds: field)
        }
    }

    private struct ThrowingEngine: InferenceEngine, @unchecked Sendable {
        let error: Error
        var name: String { "throwing" }
        func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    private struct FixedContext: ContextProvider {
        let prefix: String
        let suffix: String
        func provideContext(for request: CompletionRequest) async throws -> CompletionContext {
            CompletionContext(prefix: prefix, suffix: suffix, language: nil, appIdentifier: request.appIdentifier)
        }
    }

    private final class HeldEngine: InferenceEngine, @unchecked Sendable {
        let name = "held"
        private let held: AsyncThrowingStream<CompletionEvent, Error>
        private let continuation: AsyncThrowingStream<CompletionEvent, Error>.Continuation
        init() {
            var captured: AsyncThrowingStream<CompletionEvent, Error>.Continuation!
            held = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
        func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> { held }
        func token(_ text: String) { continuation.yield(.token(text)) }
        func finish() { continuation.yield(.end); continuation.finish() }
    }

    private struct Rig {
        let controller: CompletionController
        let notShown: NotShownStore
        let focus: StubFocusIdentityProvider
        let renderer: GhostTextRenderer
    }

    private func makeRig(
        engine: InferenceEngine? = MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
        app: String = NotShownReasonTests.editor,
        focus: FocusTarget? = NotShownReasonTests.focus,
        geometry: InlineCaretGeometryProvider? = FixedGeometry(),
        context: ContextProvider? = nil,
        enabled: Bool = true,
        noModel: Bool = false
    ) -> Rig {
        let defaults = makeUserDefaults()
        defaults.set(enabled, forKey: "enableCompletions")
        let notShown = NotShownStore(fileURL: tempFileURL("not-shown"), debounce: 60)
        let stub = StubFocusIdentityProvider(focus)
        let renderer = GhostTextRenderer(geometryProvider: geometry)
        let manager = EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() })
        if noModel { manager.refreshToPath(nil) }
        let controller = CompletionController(
            engineManager: manager,
            personalization: makePersonalizationStore("not-shown"),
            overrides: AppOverridesStore(fileURL: tempFileURL("not-shown-overrides")),
            notShown: notShown,
            inserter: RecordingInserter(),
            renderer: renderer,
            pipelineEngineOverride: noModel ? nil : engine,
            daemonEngineProvider: { _ in nil },
            contextProviderOverride: context,
            frontmostAppProvider: { app },
            focusIdentityProvider: stub,
            userDefaults: defaults
        )
        controller.completionsEnabled = enabled
        return Rig(controller: controller, notShown: notShown, focus: stub, renderer: renderer)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func count(_ rig: Rig, _ reason: NotShownReason, app: String = NotShownReasonTests.editor) -> Int {
        rig.notShown.snapshot.perApp[app]?[reason.rawValue]?.count ?? 0
    }

    func testCompletionsDisabled() {
        let rig = makeRig(enabled: false)
        XCTAssertFalse(rig.controller.trigger())
        XCTAssertEqual(count(rig, .completionsDisabled), 1)
    }

    func testAppDisabledByDefaultForTerminals() {
        let rig = makeRig(app: "com.mitchellh.ghostty")
        XCTAssertFalse(rig.controller.trigger())
        XCTAssertEqual(count(rig, .appDisabled, app: "com.mitchellh.ghostty"), 1)
    }

    func testNoModel() {
        let rig = makeRig(noModel: true)
        XCTAssertFalse(rig.controller.trigger())
        XCTAssertEqual(count(rig, .noModel), 1)
    }

    func testNoFocusedEditor() {
        let rig = makeRig(focus: nil)
        XCTAssertFalse(rig.controller.trigger())
        XCTAssertEqual(count(rig, .noFocusedEditor), 1)
    }

    func testSensitiveCategoriesAreCountedSeparately() async {
        let cases: [(SensitiveContextError, NotShownReason)] = [
            (.gated(.secureTextField), .secureField),
            (.gated(.protectedContent), .protectedContent),
            (.gated(.sensitiveApp), .sensitiveApp),
            (.gated(.userExcludedApp), .userExcludedApp),
            (.unreadable, .unreadableContext),
        ]
        for (error, reason) in cases {
            let rig = makeRig(engine: ThrowingEngine(error: error))
            XCTAssertTrue(rig.controller.trigger())
            let counted = await waitUntil { self.count(rig, reason) == 1 }
            XCTAssertTrue(counted, "\(reason.rawValue)")
        }
    }

    func testEngineFailure() async {
        let rig = makeRig(engine: ThrowingEngine(error: EngineError.noModel))
        XCTAssertTrue(rig.controller.trigger())
        let counted = await waitUntil { self.count(rig, .engineFailure) == 1 }
        XCTAssertTrue(counted)
    }

    func testEmptyCompletion() async {
        let rig = makeRig(engine: MockInferenceEngine(response: "", wordDelayNanoseconds: 0))
        XCTAssertTrue(rig.controller.trigger())
        let counted = await waitUntil { self.count(rig, .emptyCompletion) == 1 }
        XCTAssertTrue(counted)
    }

    func testAbstainedInsideWordIsNotCountedAsEmpty() async {
        let rig = makeRig(context: FixedContext(prefix: "hel", suffix: "lo there"))
        XCTAssertTrue(rig.controller.trigger())
        let counted = await waitUntil { self.count(rig, .abstainedInsideWord) == 1 }
        XCTAssertTrue(counted)
        XCTAssertEqual(count(rig, .emptyCompletion), 0)
    }

    func testCancelledWhileGenerating() async {
        let engine = HeldEngine()
        let rig = makeRig(engine: engine)
        XCTAssertTrue(rig.controller.trigger())
        _ = await waitUntil { rig.controller.phase == .generating }
        rig.controller.dismiss()
        XCTAssertEqual(count(rig, .cancelledWhileGenerating), 1)
    }

    func testFocusChangedDuringGeneration() async {
        let engine = HeldEngine()
        let rig = makeRig(engine: engine)
        XCTAssertTrue(rig.controller.trigger())
        _ = await waitUntil { rig.controller.phase == .generating }
        rig.focus.current = Self.movedFocus
        engine.finish()
        let counted = await waitUntil { self.count(rig, .focusChangedDuringGeneration) == 1 }
        XCTAssertTrue(counted)
    }

    func testFocusMismatchAtRender() async {
        let engine = HeldEngine()
        let rig = makeRig(engine: engine)
        XCTAssertTrue(rig.controller.trigger())
        _ = await waitUntil { rig.controller.phase == .generating }
        rig.focus.current = Self.movedFocus
        engine.token("hello ")
        let counted = await waitUntil { self.count(rig, .focusMismatchAtRender) >= 1 }
        XCTAssertTrue(counted)
        XCTAssertEqual(count(rig, .focusMismatchAtRender), 1, "one count per request however many redraws fail")
        engine.finish()
    }

    func testNoCaretGeometryIsCountedOncePerRequest() async {
        let engine = HeldEngine()
        let rig = makeRig(engine: engine, geometry: nil)
        XCTAssertTrue(rig.controller.trigger())
        _ = await waitUntil { rig.controller.phase == .generating }
        for token in ["one ", "two ", "three"] {
            engine.token(token)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        engine.finish()
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(count(rig, .noCaretGeometry), 1)
    }

    func testRendererReportsGhostDoesNotFit() {
        let renderer = GhostTextRenderer(geometryProvider: FixedGeometry())
        var reasons: [NotShownReason] = []
        renderer.onNotShown = { reasons.append($0) }
        renderer.show(candidate: "")
        XCTAssertEqual(reasons, [.ghostDoesNotFit])
    }

    func testRendererReportsNoCaretGeometry() {
        let renderer = GhostTextRenderer(geometryProvider: nil)
        var reasons: [NotShownReason] = []
        renderer.onNotShown = { reasons.append($0) }
        renderer.show(candidate: "hello")
        XCTAssertEqual(reasons, [.noCaretGeometry])
    }

    func testRendererReportsNothingWhenTheGhostIsDrawn() {
        let renderer = GhostTextRenderer(geometryProvider: FixedGeometry())
        var reasons: [NotShownReason] = []
        renderer.onNotShown = { reasons.append($0) }
        renderer.show(candidate: "hello")
        XCTAssertTrue(reasons.isEmpty)
        renderer.clear()
    }

    func testVisibleGhostRecordsNothing() async {
        let rig = makeRig(engine: MockInferenceEngine(response: "hello world", wordDelayNanoseconds: 0))
        XCTAssertTrue(rig.controller.trigger())
        let visible = await waitUntil { rig.controller.isGhostVisible }
        XCTAssertTrue(visible)
        XCTAssertEqual(rig.notShown.snapshot.totalCount, 0)
    }

    func testControllerWithoutAStoreRecordsNothing() {
        let defaults = makeUserDefaults()
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: makePersonalizationStore("not-shown-none"),
            overrides: AppOverridesStore(fileURL: tempFileURL("not-shown-none-overrides")),
            frontmostAppProvider: { Self.editor },
            userDefaults: defaults
        )
        controller.completionsEnabled = false
        XCTAssertFalse(controller.trigger())
    }
}
