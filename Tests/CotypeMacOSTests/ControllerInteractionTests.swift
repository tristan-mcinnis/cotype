import XCTest
import CotypeCore
@testable import CotypeMacOS

// MARK: - CompletionController × CompletionInteraction seam

/// Drives the interaction loop through the controller's public seam and verifies
/// the manual-first wiring: typing/editing/pointer changes never start a
/// generation, an explicit trigger does, an edit while a candidate is showing
/// dismisses it, and Tab / accept-all / Escape keep working. Gating (disabled app
/// / sensitive context) must survive the seam.
@MainActor
final class ControllerInteractionTests: XCTestCase {

    private func makeController(
        engine: InferenceEngine,
        frontmostAppProvider: @escaping () -> String? = { "com.example.editor" },
        focusProvider: FocusIdentityProvider? = nil,
        renderer: CompletionRenderer = GhostTextRenderer()
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let personalization = makePersonalizationStore()
        let overrides = AppOverridesStore(fileURL: tempFileURL("overrides"))
        let inserter = RecordingInserter()
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: personalization,
            overrides: overrides,
            inserter: inserter,
            renderer: renderer,
            pipelineEngineOverride: engine,
            frontmostAppProvider: frontmostAppProvider,
            focusIdentityProvider: focusProvider ?? StubFocusIdentityProvider(Self.stableFocus),
            userDefaults: defaults
        )
        controller.debounceInterval = 0.02
        controller.cooldownInterval = 0.02
        return (controller, inserter)
    }

    private static let stableFocus = FocusTarget(
        appIdentifier: "com.example.editor",
        windowIdentity: 1,
        elementIdentity: 2,
        selection: .unsupported
    )

    private struct FixedGeometry: InlineCaretGeometryProvider {
        func caretGeometry() -> CaretGeometry? {
            CaretGeometry(
                caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
                fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200)
            )
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Long enough for a 0.02 s debounce to have fired ten times over.
    private func assertStaysIdle(_ controller: CompletionController, line: UInt = #line) async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.phase, .idle, line: line)
        XCTAssertFalse(controller.candidateAvailable, line: line)
    }

    // MARK: - Manual-first: idle input never generates

    func testTypingDoesNotStartAGeneration() async {
        let (controller, inserter) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        controller.noteTyped("h")
        controller.noteTyped("e")
        await assertStaysIdle(controller)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertNil(controller.lastError)
    }

    func testEditingDoesNotStartAGeneration() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        controller.noteEdited()
        await assertStaysIdle(controller)
    }

    func testPointerContextChangeDoesNotStartAGeneration() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        controller.noteContextMoved()
        await assertStaysIdle(controller)
    }

    // MARK: - Manual trigger drives the loop

    func testManualTriggerGeneratesAndShowsCandidate() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.currentCandidate, "hello")
    }

    func testManualTriggerSupersedesInFlightGeneration() async {
        let scripted = ScriptedEngine(["first candidate", "second candidate"], wordDelayNanoseconds: 20_000_000)
        let (controller, _) = makeController(engine: scripted)
        XCTAssertTrue(controller.trigger())   // generation 1 (slow)
        // Wait until generation 1 has actually started its stream (and consumed
        // its scripted response) so supersession is tested, not task ordering.
        let inFlight = await waitUntil { scripted.callsStarted == 1 }
        XCTAssertTrue(inFlight)
        XCTAssertTrue(controller.trigger())   // generation 2 supersedes
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.currentCandidate, "second candidate")
    }

    func testManualTriggerDuringCooldownStillWorks() async {
        let scripted = ScriptedEngine(["hello", "world"], wordDelayNanoseconds: 0)
        let (controller, _) = makeController(engine: scripted)
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        controller.dismiss()                     // Escape -> cooldown
        XCTAssertFalse(controller.candidateAvailable)
        XCTAssertTrue(controller.trigger(), "the explicit trigger overrides the cooldown")
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
    }

    // MARK: - Edits cancel / dismiss instead of regenerating

    func testTypingWhileGeneratingCancelsToIdle() async {
        let scripted = ScriptedEngine(["a slow candidate that will not arrive"], wordDelayNanoseconds: 40_000_000)
        let (controller, _) = makeController(engine: scripted)
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .generating }

        controller.noteTyped("i")
        await assertStaysIdle(controller)
        XCTAssertFalse(controller.hasPendingCompletion)
    }

    func testTypingWhileCandidateIsShowingDismissesWithoutInserting() async {
        let (controller, inserter) = makeController(engine: MockInferenceEngine(response: "ello world", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertEqual(controller.currentCandidate, "ello world")

        // Even a matching character is an edit: manual-first dismisses the ghost
        // instead of typing through it and regenerating.
        controller.noteTyped("e")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.candidateAvailable)
        await assertStaysIdle(controller)
        XCTAssertTrue(inserter.inserted.isEmpty, "typing must never insert")
    }

    func testEditingWhileCandidateIsShowingDismisses() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "ello", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        controller.noteEdited()   // e.g. Backspace / Return / Cmd+Z
        XCTAssertFalse(controller.hasPendingCompletion)
        XCTAssertTrue(controller.currentCandidate.isEmpty)
        await assertStaysIdle(controller)
    }

    func testPointerContextChangeWhileShowingDismisses() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "ello", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        controller.noteContextMoved()   // mouse-down moved the caret
        XCTAssertFalse(controller.hasPendingCompletion)
        XCTAssertTrue(controller.currentCandidate.isEmpty)
        await assertStaysIdle(controller)
    }

    // MARK: - Accept next word (stepping) / accept all

    func testAcceptNextWordInsertsOnlyNextWordAndSteps() async {
        let (controller, inserter) = makeController(engine: MockInferenceEngine(response: "world peace", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertEqual(controller.currentCandidate, "world peace")

        controller.acceptNextWord()
        _ = await waitUntil { inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["world "])
        XCTAssertEqual(controller.phase, .awaitingAccept, "remaining ghost stays awaiting")
        XCTAssertEqual(controller.currentCandidate, "peace")

        controller.acceptNextWord()
        _ = await waitUntil { inserter.inserted.count == 2 }
        XCTAssertEqual(inserter.inserted, ["world ", "peace"])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.currentCandidate.isEmpty)
    }

    func testAcceptAllInsertsWholeSuggestion() async {
        let (controller, inserter) = makeController(engine: MockInferenceEngine(response: "world peace", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        controller.accept() // full-suggestion shortcut / menu Accept
        _ = await waitUntil { inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["world peace"])
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Escape dismiss + pause

    func testEscapeDismissesAndPauses() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        controller.dismiss() // Escape
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.currentCandidate.isEmpty)
    }

    // MARK: - Overlay visibility metrics

    func testInvisibleOverlayIsNotCountedAsShown() async {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let personalization = makePersonalizationStore("hidden-overlay")
        let renderer = GhostTextRenderer(geometryProvider: nil)
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: personalization,
            overrides: AppOverridesStore(fileURL: tempFileURL("hidden-overlay-overrides")),
            inserter: RecordingInserter(),
            renderer: renderer,
            pipelineEngineOverride: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(Self.stableFocus),
            userDefaults: defaults
        )

        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertFalse(renderer.isShowing, "the injected renderer has no usable geometry")
        XCTAssertEqual(
            personalization.metricCounts.shown,
            0,
            "a generated candidate must not be reported as shown when no overlay became visible"
        )
    }

    /// A ready candidate whose ghost could not be drawn (no caret geometry) must
    /// not take the accept key: Tab would otherwise insert text the user never
    /// saw instead of reaching the app.
    func testHiddenGhostDoesNotTakeTheAcceptKey() async {
        let (controller, _) = makeController(
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            renderer: GhostTextRenderer(geometryProvider: nil)
        )
        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertTrue(controller.hasPendingCompletion)
        XCTAssertFalse(controller.isGhostVisible)
        XCTAssertFalse(controller.isAcceptKeyReady, "a hidden ghost must leave Tab to the app")
    }

    func testVisibleGhostTakesTheAcceptKeyUntilItIsGone() async {
        let (controller, _) = makeController(
            engine: MockInferenceEngine(response: "hello world", wordDelayNanoseconds: 0),
            renderer: GhostTextRenderer(geometryProvider: FixedGeometry())
        )
        XCTAssertTrue(controller.trigger())
        let visible = await waitUntil { controller.phase == .awaitingAccept && controller.isGhostVisible }
        XCTAssertTrue(visible)
        XCTAssertTrue(controller.isAcceptKeyReady)

        controller.dismiss()
        let hidden = await waitUntil { !controller.isGhostVisible }
        XCTAssertTrue(hidden)
        XCTAssertFalse(controller.isAcceptKeyReady)
    }

    func testVisibleOverlayIsCountedOnceAsShown() async {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let personalization = makePersonalizationStore("visible-overlay")
        let renderer = GhostTextRenderer(geometryProvider: FixedGeometry())
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: personalization,
            overrides: AppOverridesStore(fileURL: tempFileURL("visible-overlay-overrides")),
            inserter: RecordingInserter(),
            renderer: renderer,
            pipelineEngineOverride: MockInferenceEngine(response: "hello world", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(Self.stableFocus),
            userDefaults: defaults
        )

        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertTrue(renderer.isShowing)
        XCTAssertEqual(
            personalization.metricCounts.shown,
            1,
            "streaming redraws for one candidate must contribute only one shown metric"
        )
    }

    // MARK: - Gating preserved through the seam

    func testDisabledCompletionsGateManualTrigger() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        controller.completionsEnabled = false
        XCTAssertFalse(controller.trigger())
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastError, "Completions are disabled.")
    }

    func testSensitiveContextGateThroughManualTrigger() async {
        let (controller, _) = makeController(
            engine: SensitiveThrowingEngine(),
            frontmostAppProvider: { "com.example.editor" }
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { !(controller.lastError ?? "").isEmpty }
        XCTAssertEqual(controller.phase, .idle, "sensitive context must never leave a candidate")
        XCTAssertEqual(controller.lastError, "Completion is disabled for this sensitive app.")
    }

    // MARK: - Streaming cost: focus is not re-resolved per token

    func testFocusIsResolvedOncePerGenerationNotPerStreamedToken() async {
        let provider = CountingFocusIdentityProvider(Self.stableFocus)
        let renderer = CountingRenderer()
        let engine = ManualStreamEngine()
        let (controller, _) = makeController(
            engine: engine,
            focusProvider: provider,
            renderer: renderer
        )

        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .generating }
        XCTAssertEqual(provider.callCount, 1, "the trigger resolves the focused editor exactly once")

        // Feed four tokens, waiting for each to reach the renderer, so the
        // streaming path demonstrably ran (a per-token AX read would show up here).
        for (index, token) in ["one ", "two ", "three ", "four "].enumerated() {
            engine.yieldToken(token)
            let delivered = await waitUntil { renderer.presented.count > index }
            XCTAssertTrue(delivered, "token \(index) must reach the renderer")
            XCTAssertEqual(provider.callCount, 1, "streamed token \(index) must not re-resolve the focused editor")
        }
        engine.finish()

        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.currentCandidate, "one two three four")
        XCTAssertEqual(
            provider.callCount,
            2,
            "two reads per generation — the trigger and the candidate boundary — never one per streamed token"
        )
        XCTAssertEqual(renderer.presented.last, "one two three four")
        XCTAssertGreaterThanOrEqual(renderer.presented.count, 4, "each streamed token was delivered")
    }

    func testMovedFocusBeforeAcceptFailsClosed() async {
        let provider = StubFocusIdentityProvider(Self.stableFocus)
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            focusProvider: provider
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        // The caret moved to another field/window after the candidate arrived.
        provider.current = FocusTarget(
            appIdentifier: "com.example.editor",
            windowIdentity: 1,
            elementIdentity: 999,
            selection: .unsupported
        )
        controller.accept()
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(inserter.inserted.isEmpty, "a moved focus target must not be inserted into")
        XCTAssertFalse(controller.hasPendingCompletion)
    }

    // MARK: - Rapid Tab commits are serialized in order

    func testRapidTabSteppingSerializesCommitsInOrder() async {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let personalization = makePersonalizationStore()
        let overrides = AppOverridesStore(fileURL: tempFileURL("overrides"))
        let inserter = SlowInserter(delayNanoseconds: 5_000_000)
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: personalization,
            overrides: overrides,
            inserter: inserter,
            pipelineEngineOverride: MockInferenceEngine(response: "one two three four", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(Self.stableFocus),
            userDefaults: defaults
        )
        controller.debounceInterval = 0.02
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertEqual(controller.currentCandidate, "one two three four")

        // Fire the four step-accepts back-to-back; a slow inserter would reorder
        // them if the commits were not serialized.
        controller.acceptNextWord()
        controller.acceptNextWord()
        controller.acceptNextWord()
        controller.acceptNextWord()

        let done = await waitUntil { inserter.inserted.count == 4 }
        XCTAssertTrue(done)
        XCTAssertEqual(inserter.inserted, ["one ", "two ", "three ", "four"])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.currentCandidate.isEmpty)
    }

    // MARK: - Stepped remainder stays valid under the render guard (era fix)

    func testFirstTabLeavesRemainderUnderGuard() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "world peace", wordDelayNanoseconds: 0))
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertEqual(controller.currentCandidate, "world peace")

        // First Tab accepts the next word; the remainder ghost must remain a valid
        // awaiting candidate (the render guard must NOT reject it because a
        // stepped accept bumped flow.generation).
        controller.acceptNextWord()
        XCTAssertEqual(controller.phase, .awaitingAccept, "remainder must still be awaiting")
        XCTAssertEqual(controller.currentCandidate, "peace", "the remainder ghost must be retained")
        XCTAssertFalse(controller.currentCandidate.isEmpty)
    }

    // MARK: - Focus revalidation between queued segments

    func testRapidTabReReadsCurrentFocusTarget() async {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let initialFocus = FocusTarget(
            appIdentifier: "com.example.editor",
            windowIdentity: 1,
            elementIdentity: 2,
            selection: .range(.init(location: 0, length: 0))
        )
        let provider = StubFocusIdentityProvider(initialFocus)
        let inserter = AdvancingTargetInserter(provider: provider)
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: makePersonalizationStore(),
            overrides: AppOverridesStore(fileURL: tempFileURL("overrides")),
            inserter: inserter,
            pipelineEngineOverride: MockInferenceEngine(response: "one two", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: provider,
            userDefaults: defaults
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        controller.acceptNextWord()
        controller.acceptNextWord()
        let done = await waitUntil { inserter.inserts.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(inserter.texts, ["one ", "two"])
        // Each segment re-reads the caret left by the preceding insert, even when
        // both Tabs were queued before the first insert completed.
        XCTAssertEqual(inserter.inserts.map(\.focusTarget), [
            initialFocus,
            FocusTarget(
                appIdentifier: "com.example.editor",
                windowIdentity: 1,
                elementIdentity: 2,
                selection: .range(.init(location: 4, length: 0))
            ),
        ])
    }

    func testMovedFocusBetweenSegmentsFailsClosed() async {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let inserter = SlowInserter(delayNanoseconds: 5_000_000)
        let provider = StubFocusIdentityProvider(Self.stableFocus)
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: makePersonalizationStore(),
            overrides: AppOverridesStore(fileURL: tempFileURL("overrides")),
            inserter: inserter,
            pipelineEngineOverride: MockInferenceEngine(response: "one two three", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: provider,
            userDefaults: defaults
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        controller.acceptNextWord()   // "one " lands
        _ = await waitUntil { inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["one "])

        // The user moved the caret to a different field / window: the captured
        // exact target no longer matches before the next queued segment.
        provider.current = FocusTarget(
            appIdentifier: "com.example.editor",
            windowIdentity: 1,
            elementIdentity: 999,
            selection: .unsupported
        )
        controller.acceptNextWord()   // "two " -> must fail closed, not insert
        _ = await waitUntil { !controller.hasPendingCompletion }
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(inserter.inserted, ["one "], "the moved-caret segment must not insert")
        XCTAssertTrue(controller.currentCandidate.isEmpty)
        XCTAssertEqual(controller.lastError, "The focus changed before the completion was inserted.")
    }
}

// MARK: - Streamed candidate coalescing (pure seam)

final class StreamedCandidateCoalescerTests: XCTestCase {

    func testBurstCollapsesToTheNewestCandidatePerTurn() {
        var scheduled: [() -> Void] = []
        var delivered: [StreamedCandidateCoalescer.Pending] = []
        let coalescer = StreamedCandidateCoalescer(
            schedule: { scheduled.append($0) },
            deliver: { delivered.append($0) }
        )

        coalescer.submit("a", generationID: 1)
        coalescer.submit("ab", generationID: 1)
        coalescer.submit("abc", generationID: 1)

        XCTAssertTrue(delivered.isEmpty, "nothing is delivered before the drain runs")
        XCTAssertEqual(scheduled.count, 1, "a burst schedules exactly one pending update")
        scheduled.forEach { $0() }
        XCTAssertEqual(delivered.map(\.text), ["abc"], "the newest candidate wins")
        XCTAssertEqual(delivered.map(\.generationID), [1])
    }

    func testASubmissionAfterDeliverySchedulesANewDrain() {
        var scheduled: [() -> Void] = []
        var delivered: [StreamedCandidateCoalescer.Pending] = []
        let coalescer = StreamedCandidateCoalescer(
            schedule: { scheduled.append($0) },
            deliver: { delivered.append($0) }
        )

        coalescer.submit("a", generationID: 1)
        scheduled.forEach { $0() }
        coalescer.submit("ab", generationID: 1)
        XCTAssertEqual(scheduled.count, 2)
        scheduled.forEach { $0() }
        XCTAssertEqual(delivered.map(\.text), ["a", "ab"])
    }

    func testEmptyDrainDeliversNothing() {
        var delivered: [StreamedCandidateCoalescer.Pending] = []
        let coalescer = StreamedCandidateCoalescer(
            schedule: { _ in },
            deliver: { delivered.append($0) }
        )
        coalescer.drain()
        XCTAssertTrue(delivered.isEmpty)
    }
}

// MARK: - Test doubles

/// Counts every focused-editor resolution so a test can prove the streaming path
/// no longer performs one per token.
@MainActor
private final class CountingFocusIdentityProvider: FocusIdentityProvider {
    private(set) var callCount = 0
    var current: FocusTarget?
    init(_ current: FocusTarget?) { self.current = current }
    func currentFocusTarget() -> FocusTarget? {
        callCount += 1
        return current
    }
}

/// Records the controller-driven renders (via `CollectingRenderer.setGhost`) and
/// never touches AppKit or Accessibility.
private final class CountingRenderer: CompletionRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var _presented: [String] = []
    private var _clearCount = 0

    func present(_ candidate: String, for request: CompletionRequest) {
        lock.lock(); _presented.append(candidate); lock.unlock()
    }

    func clear() {
        lock.lock(); _clearCount += 1; lock.unlock()
    }

    var presented: [String] {
        lock.lock(); defer { lock.unlock() }
        return _presented
    }

    var clearCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _clearCount
    }
}

/// A stream the test drives token by token, so each candidate delivery is
/// observed before the next token is produced. Fully deterministic — no timers.
private final class ManualStreamEngine: InferenceEngine, @unchecked Sendable {
    let name = "manual-stream"
    private let stream: AsyncThrowingStream<CompletionEvent, Error>
    private let continuation: AsyncThrowingStream<CompletionEvent, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<CompletionEvent, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> { stream }

    func yieldToken(_ token: String) { continuation.yield(.token(token)) }

    func finish() {
        continuation.yield(.end)
        continuation.finish()
    }
}

/// Records each exact target and advances the stub provider to the caret that
/// the insertion leaves, mirroring a real AX editor for queued-step tests.
private final class AdvancingTargetInserter: CompletionInserter, @unchecked Sendable {
    struct Insert { let text: String; let focusTarget: FocusTarget? }
    var inserts: [Insert] { lock.withLock { _inserts } }
    var texts: [String] { inserts.map(\.text) }
    private var _inserts: [Insert] = []
    private let lock = NSLock()
    private let provider: StubFocusIdentityProvider

    @MainActor
    init(provider: StubFocusIdentityProvider) {
        self.provider = provider
    }

    func insert(_ text: String) async throws { try await insert(text, appIdentifier: nil) }
    func insert(_ text: String, appIdentifier: String?) async throws {
        try await insert(text, appIdentifier: appIdentifier, focusTarget: nil)
    }
    func insert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws {
        lock.withLock { _inserts.append(Insert(text: text, focusTarget: focusTarget)) }
        guard let focusTarget,
              let nextRange = focusTarget.expectedSelectionAfterInserting(text) else { return }
        await MainActor.run {
            provider.current = FocusTarget(
                appIdentifier: focusTarget.appIdentifier,
                windowIdentity: focusTarget.windowIdentity,
                elementIdentity: focusTarget.elementIdentity,
                selection: .range(nextRange)
            )
        }
    }
}

/// An inserter with a per-insert delay so serialization is observable: if commit
/// tasks are not chained in order, the recorded order would scramble.
private final class SlowInserter: CompletionInserter, @unchecked Sendable {
    var inserted: [String] = []
    let delayNanoseconds: UInt64
    private let lock = NSLock()

    init(delayNanoseconds: UInt64 = 10_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func insert(_ text: String) async throws {
        try await insert(text, appIdentifier: nil)
    }

    func insert(_ text: String, appIdentifier: String?) async throws {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        lock.withLock { inserted.append(text) }
    }
}

/// An engine whose generation is gated as a sensitive context. This exercises the
/// same controller path the real Accessibility provider takes when it fails closed
/// (a `SensitiveContextError` out of the pipeline) while keeping the seam testable.
private struct SensitiveThrowingEngine: InferenceEngine, @unchecked Sendable {
    var name: String { "sensitive" }
    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SensitiveContextError.gated(.sensitiveApp))
        }
    }
}
