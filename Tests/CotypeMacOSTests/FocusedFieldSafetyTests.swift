import XCTest
import CotypeCore
@testable import CotypeMacOS

// MARK: - FocusIdentityPolicy (pure focus-field guard)

final class FocusIdentityPolicyTests: XCTestCase {

    private let fieldA = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 10, selection: .unsupported)
    private let fieldB = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 20, selection: .unsupported)
    private let windowB = FocusTarget(appIdentifier: "com.a", windowIdentity: 2, elementIdentity: 10, selection: .unsupported)
    private let appB = FocusTarget(appIdentifier: "com.b", windowIdentity: 1, elementIdentity: 10, selection: .unsupported)

    func testSameTargetIsValid() {
        XCTAssertTrue(FocusIdentityPolicy.isValid(captured: fieldA, current: fieldA))
    }

    func testSameAppDifferentElementCancels() {
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: fieldA, current: fieldB))
    }

    func testSameAppDifferentWindowCancels() {
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: fieldA, current: windowB))
    }

    func testDifferentAppCancels() {
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: fieldA, current: appB))
    }

    func testFocusLostCancels() {
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: fieldA, current: nil))
    }

    func testNoCapturedFieldFailsClosed() {
        // Fail closed: if no exact focused field was captured, a pending
        // completion must not render/accept/insert.
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: nil, current: fieldB))
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: nil, current: nil))
    }

    func testFocusUnreadableFailsClosed() {
        // If the current focus can no longer be re-read, we cannot verify the
        // exact target, so we do not proceed.
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: fieldA, current: nil))
    }

    // MARK: - Caret/selection revalidation

    private func withSelection(_ location: Int, _ length: Int) -> FocusTarget {
        FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 10,
                    selection: .range(FocusTarget.SelectionRange(location: location, length: length)))
    }

    func testCaretMovedWithinSameElementIsInvalid() {
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: withSelection(5, 0), current: withSelection(9, 0)))
    }

    func testSelectionLengthChangedIsInvalid() {
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: withSelection(5, 0), current: withSelection(5, 4)))
    }

    func testRangeCapturedButNowUnreadableFailsClosed() {
        // A captured caret range that can no longer be re-read (nil) is a mismatch:
        // we cannot verify the insertion point, so we refuse.
        let captured = withSelection(5, 0)
        let current = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 10, selection: nil)
        XCTAssertFalse(FocusIdentityPolicy.isValid(captured: captured, current: current))
    }

    func testNoRangeCapturedFallsBackToElementOnlyCheck() {
        // Editors that do not expose a selection range are not broken: element
        // identity alone is enough.
        XCTAssertTrue(FocusIdentityPolicy.isValid(captured: fieldA, current: fieldA))
    }

    func testRangeMatchesIsValid() {
        XCTAssertTrue(FocusIdentityPolicy.isValid(captured: withSelection(5, 0), current: withSelection(5, 0)))
    }

    func testExpectedSelectionAfterInsertingUsesUTF16() {
        // AX ranges are UTF-16 code units. An emoji is 1 String.count but 2 UTF-16
        // units, so the caret moves by 2, not by 1.
        XCTAssertEqual(withSelection(5, 0).expectedSelectionAfterInserting("😀"), FocusTarget.SelectionRange(location: 7, length: 0))
        XCTAssertEqual(withSelection(5, 0).expectedSelectionAfterInserting("ab"), FocusTarget.SelectionRange(location: 7, length: 0))
        XCTAssertNil(fieldA.expectedSelectionAfterInserting("ab"))
    }

    func testExpectedSelectionOverflowFailsClosed() {
        XCTAssertNil(withSelection(Int.max, 0).expectedSelectionAfterInserting("x"))
    }

    func testSelectionReplacementEndsAtCaretAfterInsertedText() {
        // Replacing a selection (L=5, N=4) leaves a plain caret at L + utf16(text).
        let selected = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 10,
                                   selection: .range(FocusTarget.SelectionRange(location: 5, length: 4)))
        XCTAssertEqual(selected.expectedSelectionAfterInserting("xy"), FocusTarget.SelectionRange(location: 7, length: 0))
        XCTAssertEqual(selected.expectedSelectionAfterInserting("xyz"), FocusTarget.SelectionRange(location: 8, length: 0))
    }
}

// MARK: - Focused-field safety in the completion controller

@MainActor
final class FocusedFieldControllerTests: XCTestCase {

    private func makeController(
        engine: InferenceEngine,
        focus: StubFocusIdentityProvider,
        appIdentifier: String = "com.example.editor"
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeUserDefaults()
        defaults.set(false, forKey: "learnFromFeedback")
        defaults.set(true, forKey: "enableCompletions")
        let personalization = makePersonalizationStore()
        let overrides = AppOverridesStore(fileURL: tempFileURL("overrides"))
        let inserter = RecordingInserter()
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: personalization,
            overrides: overrides,
            websiteRules: makeWebsiteRulesStore(),
            inserter: inserter,
            renderer: GhostTextRenderer(geometryProvider: FixedCaretGeometry()),
            pipelineEngineOverride: engine,
            frontmostAppProvider: { appIdentifier },
            focusIdentityProvider: focus,
            userDefaults: defaults
        )
        return (controller, inserter)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testSameAppFieldChangeBeforeAcceptCancelsAndNeverInserts() async {
        let focus = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "done", wordDelayNanoseconds: 0),
            focus: focus
        )
        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.currentCandidate, "done")

        // Same app, but the user moved to a different field.
        focus.current = FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 99, selection: .unsupported)
        controller.accept()

        // Nothing may be inserted into the now-different field.
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testSameAppWindowChangeDuringGenerationCancels() async {
        let focus = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "hello world", wordDelayNanoseconds: 40_000_000),
            focus: focus
        )
        XCTAssertTrue(controller.trigger())
        // Focus moves to another window in the SAME app while generating.
        focus.current = FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 2, elementIdentity: 1, selection: .unsupported)

        let cancelled = await waitUntil { controller.phase == .idle && !controller.candidateAvailable }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(controller.candidateAvailable)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testStableFocusStillInsertsIntoOriginalApp() async {
        let focus = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            focus: focus
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        controller.accept()
        _ = await waitUntil { inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.insertedApps, ["com.example.editor"])
    }

    func testTriggerRefusesWhenFocusUnidentifiable() {
        let focus = StubFocusIdentityProvider(nil)
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            focus: focus
        )
        // No exact focused editor could be identified: fail closed, do not start.
        XCTAssertFalse(controller.trigger())
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastError, "Cotype could not identify the focused editor. Check Accessibility permission.")
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testFocusUnreadableAtAcceptCancelsAndDoesNotInsert() async {
        let focus = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "done", wordDelayNanoseconds: 0),
            focus: focus
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        // The focused editor can no longer be read before we accept.
        focus.current = nil
        controller.accept()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
    }
}

// MARK: - Direct-vs-fallback insertion routing

@MainActor
final class RecordingDirectInserter: DirectTextInserter {
    let outcome: DirectInsertionOutcome
    var inserted: [String] = []
    var insertedFocus: [FocusTarget] = []
    init(_ outcome: DirectInsertionOutcome) {
        self.outcome = outcome
    }
    func insertDirect(_ text: String, appIdentifier: String, focusTarget: FocusTarget) -> DirectInsertionOutcome {
        inserted.append(text)
        insertedFocus.append(focusTarget)
        return outcome
    }
}

@MainActor
final class InsertionRouterTests: XCTestCase {

    private let captured = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)

    private func router(
        direct: RecordingDirectInserter,
        provider: StubFocusIdentityProvider? = nil,
        pasteboard: RecordingInserter = RecordingInserter(),
        maxDirect: Int = 512
    ) -> CompletionInsertionRouter {
        CompletionInsertionRouter(
            maxDirectTextLength: maxDirect,
            focusIdentityProvider: provider ?? StubFocusIdentityProvider(captured),
            directInserter: direct,
            pasteboardInserter: pasteboard
        )
    }

    func testShortSupportedCompletionRoutesDirect() async throws {
        let direct = RecordingDirectInserter(.inserted)
        let pasteboard = RecordingInserter()
        let r = router(direct: direct, pasteboard: pasteboard)
        try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)

        XCTAssertEqual(direct.inserted, ["hi"])
        XCTAssertEqual(direct.insertedFocus.last, captured, "the router must thread the FocusTarget into the direct inserter")
        XCTAssertTrue(pasteboard.inserted.isEmpty)
    }

    func testLongCompletionFallsBackToPasteboard() async throws {
        let direct = RecordingDirectInserter(.inserted)
        let pasteboard = RecordingInserter()
        let r = router(direct: direct, pasteboard: pasteboard, maxDirect: 512)
        let long = String(repeating: "a", count: 600)

        try await r.insert(long, appIdentifier: "com.a", focusTarget: captured)

        XCTAssertTrue(direct.inserted.isEmpty, "long completions must not use direct AX insertion")
        XCTAssertEqual(pasteboard.inserted, [long])
    }

    func testIncompatibleFieldFallsBackToPasteboard() async throws {
        let direct = RecordingDirectInserter(.unsupported)
        let pasteboard = RecordingInserter()
        let r = router(direct: direct, pasteboard: pasteboard)

        try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)

        XCTAssertEqual(direct.inserted, ["hi"])
        XCTAssertEqual(pasteboard.inserted, ["hi"])
    }

    func testDirectFailureThrowsAndDoesNotFallBack() async {
        let direct = RecordingDirectInserter(.failed)
        let pasteboard = RecordingInserter()
        let r = router(direct: direct, pasteboard: pasteboard)

        do {
            try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)
            XCTFail("expected directInsertFailed")
        } catch let error as InsertionError {
            XCTAssertEqual(error, .directInsertFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // A `.failed` direct write has an ambiguous commit state; the text must
        // never be re-inserted through the pasteboard (which could duplicate it).
        XCTAssertEqual(direct.inserted, ["hi"])
        XCTAssertTrue(pasteboard.inserted.isEmpty)
    }

    func testDirectInsertionOnlyRunsWhenIdentityStillValid() async throws {
        let direct = RecordingDirectInserter(.inserted)
        let pasteboard = RecordingInserter()
        let provider = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.b", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let r = router(direct: direct, provider: provider, pasteboard: pasteboard)

        // Captured target (com.a) no longer matches the live focus (com.b): direct
        // insertion must not run, and nothing may be pasted.
        do {
            try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)
            XCTFail("expected targetChanged")
        } catch let error as InsertionError {
            XCTAssertEqual(error, .targetChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(direct.inserted.isEmpty, "direct insertion must not run when identity changed")
        XCTAssertTrue(pasteboard.inserted.isEmpty)
    }

    func testNilFocusTargetFailsClosed() async {
        let direct = RecordingDirectInserter(.inserted)
        let pasteboard = RecordingInserter()
        let r = router(direct: direct, pasteboard: pasteboard)

        do {
            try await r.insert("hi", appIdentifier: "com.a", focusTarget: nil)
            XCTFail("expected targetChanged")
        } catch let error as InsertionError {
            XCTAssertEqual(error, .targetChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(pasteboard.inserted.isEmpty)
        XCTAssertTrue(direct.inserted.isEmpty)
    }

    func testFocusTargetChangedThrowsAndInsertsNothing() async {
        let direct = RecordingDirectInserter(.inserted)
        let pasteboard = RecordingInserter()
        let provider = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.b", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let r = router(direct: direct, provider: provider, pasteboard: pasteboard)

        do {
            try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)
            XCTFail("expected targetChanged")
        } catch let error as InsertionError {
            XCTAssertEqual(error, .targetChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(pasteboard.inserted.isEmpty)
        XCTAssertTrue(direct.inserted.isEmpty)
    }

    func testValidFocusTargetDoesNotBlockDirectInsertion() async throws {
        let direct = RecordingDirectInserter(.inserted)
        let pasteboard = RecordingInserter()
        let r = router(direct: direct, pasteboard: pasteboard)

        try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)

        XCTAssertEqual(direct.inserted, ["hi"])
        XCTAssertTrue(pasteboard.inserted.isEmpty)
    }
}

// MARK: - Pasteboard fallback field revalidation (insertion gap)

/// Records the field-aware overload so we can prove the router threads the
/// captured FocusTarget into the pasteboard fallback.
final class FocusRecordingInserter: CompletionInserter, @unchecked Sendable {
    var inserted: [String] = []
    var insertedFocus: [FocusTarget?] = []
    func insert(_ text: String) async throws { inserted.append(text); insertedFocus.append(nil) }
    func insert(_ text: String, appIdentifier: String?) async throws { inserted.append(text); insertedFocus.append(nil) }
    func insert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws {
        inserted.append(text)
        insertedFocus.append(focusTarget)
    }
}

/// A `ClipboardOperator` that records calls instead of touching the live
/// pasteboard or posting synthetic keys.
final class RecordingClipboardOperator: ClipboardOperator, @unchecked Sendable {
    var writeCalls = 0
    var postCalls = 0
    /// One `true` per restore actually performed (guarded by the change count).
    var restoreCalls: [Bool] = []
    /// Simulated current pasteboard change count; defaults to the write's return
    /// value (7) so the count is unchanged unless the test changes it.
    var currentChangeCount = 7
    private let initialSnapshot = ClipboardSnapshot(items: [], changeCount: 3)

    func snapshot() -> ClipboardSnapshot { initialSnapshot }
    func writeForPaste(_ text: String) -> Int? { writeCalls += 1; return 7 }
    func postPaste() { postCalls += 1 }
    @discardableResult
    func restore(_ snapshot: ClipboardSnapshot, expectedChangeCount: Int?, ignoreChangeCount: Bool) -> Bool {
        let shouldRestore = ignoreChangeCount
            || ClipboardRestorePolicy.shouldRestore(snapshotChangeCount: expectedChangeCount ?? 0, currentChangeCount: currentChangeCount)
        if shouldRestore { restoreCalls.append(true) }
        return shouldRestore
    }
}

@MainActor
final class PasteboardFocusGuardTests: XCTestCase {

    private func makeInserter(
        provider: StubFocusIdentityProvider,
        clipboard: RecordingClipboardOperator = RecordingClipboardOperator()
    ) -> PasteboardInserter {
        PasteboardInserter(
            restoreDelayNanoseconds: 1,
            focusIdentityProvider: provider,
            clipboard: clipboard,
            preflightPostEventAccess: { true }
        )
    }

    func testFocusChangeDuringPreparationPostsNothingAndRestores() async {
        let captured = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1,
                                   selection: .range(FocusTarget.SelectionRange(location: 5, length: 0)))
        let provider = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.b", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let clipboard = RecordingClipboardOperator()
        let inserter = makeInserter(provider: provider, clipboard: clipboard)

        do {
            try await inserter.insert("hi", appIdentifier: "com.a", focusTarget: captured)
            XCTFail("expected targetChanged")
        } catch let error as PasteboardInserter.InsertError {
            XCTAssertEqual(error, .targetChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(clipboard.postCalls, 0, "no Cmd+V may be posted into a changed target")
        XCTAssertTrue(clipboard.restoreCalls.contains(true), "clipboard must be restored on mismatch")
    }

    func testCaretMovedInSameElementDuringPreparationCancels() async {
        let captured = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1,
                                   selection: .range(FocusTarget.SelectionRange(location: 5, length: 0)))
        let provider = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1,
                        selection: .range(FocusTarget.SelectionRange(location: 9, length: 0)))
        )
        let clipboard = RecordingClipboardOperator()
        let inserter = makeInserter(provider: provider, clipboard: clipboard)

        do {
            try await inserter.insert("hi", appIdentifier: "com.a", focusTarget: captured)
            XCTFail("expected targetChanged")
        } catch let error as PasteboardInserter.InsertError {
            XCTAssertEqual(error, .targetChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(clipboard.postCalls, 0)
        XCTAssertFalse(clipboard.restoreCalls.isEmpty)
    }

    func testPasteboardPostsWhenFocusUnchanged() async throws {
        let captured = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1,
                                   selection: .range(FocusTarget.SelectionRange(location: 5, length: 0)))
        let provider = StubFocusIdentityProvider(captured)
        let clipboard = RecordingClipboardOperator()
        let inserter = makeInserter(provider: provider, clipboard: clipboard)

        try await inserter.insert("hi", appIdentifier: "com.a", focusTarget: captured)

        XCTAssertEqual(clipboard.postCalls, 1)
        XCTAssertEqual(clipboard.writeCalls, 1)
    }

    func testRouterThreadsFocusTargetIntoPasteboardFallback() async throws {
        // Never discard the approved field identity: the router must call the
        // field-aware pasteboard overload when falling back.
        let direct = RecordingDirectInserter(.unsupported)
        let pasteboard = FocusRecordingInserter()
        let captured = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        let r = CompletionInsertionRouter(
            maxDirectTextLength: 512,
            focusIdentityProvider: StubFocusIdentityProvider(captured),
            directInserter: direct,
            pasteboardInserter: pasteboard
        )

        try await r.insert("hi", appIdentifier: "com.a", focusTarget: captured)

        XCTAssertEqual(pasteboard.inserted, ["hi"])
        XCTAssertEqual(pasteboard.insertedFocus.last, captured, "the FocusTarget must be threaded into the pasteboard fallback")
    }

    func testFocusChangeDuringPreparationDoesNotClobberUserCopy() async {
        // If the user copied during the gap between preparation and the focus
        // re-check, the clipboard change count changes and the restore must be
        // skipped (never overwrite the user's new copy), while still posting nothing.
        let captured = FocusTarget(appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        let provider = StubFocusIdentityProvider(
            FocusTarget(appIdentifier: "com.b", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
        )
        let clipboard = RecordingClipboardOperator()
        clipboard.currentChangeCount = 99  // user copied during the gap
        let inserter = makeInserter(provider: provider, clipboard: clipboard)

        do {
            try await inserter.insert("hi", appIdentifier: "com.a", focusTarget: captured)
            XCTFail("expected targetChanged")
        } catch let error as PasteboardInserter.InsertError {
            XCTAssertEqual(error, .targetChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(clipboard.postCalls, 0, "no paste may be posted into a changed target")
        XCTAssertTrue(clipboard.restoreCalls.isEmpty, "must not restore over a user copy made during the gap")
    }
}

// MARK: - AX read categorization (optional-absence vs. fatal error)

@MainActor
final class AXReadCategorizationTests: XCTestCase {

    func testOptionalAbsenceIsSafeAbsent() {
        if case .value = LiveAXAncestryReader.categorize(.attributeUnsupported) {
            return XCTFail("attributeUnsupported must map to safe-absent, not a value")
        }
        if case .unreadable = LiveAXAncestryReader.categorize(.attributeUnsupported) {
            return XCTFail("attributeUnsupported must be safe-absent, not unreadable")
        }
        if case .unreadable = LiveAXAncestryReader.categorize(.noValue) {
            return XCTFail("noValue must be safe-absent, not unreadable")
        }
    }

    func testGenuineErrorsAreUnreadable() {
        for error in [AXError.cannotComplete, .failure, .invalidUIElement, .notImplemented] {
            guard case .unreadable = LiveAXAncestryReader.categorize(error) else {
                return XCTFail("\(error) must map to unreadable")
            }
        }
    }

    func testSuccessIsValue() {
        guard case .value = LiveAXAncestryReader.categorize(.success) else {
            return XCTFail("success must map to a value")
        }
    }
}

// MARK: - Selection-range tri-state decode (fail closed on unreadable)

@MainActor
final class SelectionDecodeTests: XCTestCase {

    func testAttributeUnsupportedFallsBackToElementOnly() {
        guard case .unsupported = AXFocusIdentityProvider.decodeSelectionRange(error: .attributeUnsupported, value: nil) else {
            return XCTFail("attributeUnsupported must map to unsupported (element-only)")
        }
    }

    func testGenuineErrorsFailClosed() {
        for error in [AXError.cannotComplete, .invalidUIElement, .noValue, .failure, .notImplemented] {
            guard case .unavailable = AXFocusIdentityProvider.decodeSelectionRange(error: error, value: nil) else {
                return XCTFail("\(error) must map to unavailable")
            }
        }
    }

    func testMalformedValueIsUnavailable() {
        // A non-AXValue payload is malformed -> identity unavailable.
        guard case .unavailable = AXFocusIdentityProvider.decodeSelectionRange(error: .success, value: "not a range" as CFString) else {
            return XCTFail("malformed value must be unavailable")
        }
    }

    func testValidCFRangeDecodes() {
        var range = CFRange(location: 4, length: 2)
        let axValue = AXValueCreate(.cfRange, &range)!
        guard case .range(let r) = AXFocusIdentityProvider.decodeSelectionRange(error: .success, value: axValue) else {
            return XCTFail("valid cfRange must decode to a range")
        }
        XCTAssertEqual(r, FocusTarget.SelectionRange(location: 4, length: 2))
    }

    func testNegativeLengthIsUnavailable() {
        var range = CFRange(location: 4, length: -1)
        let axValue = AXValueCreate(.cfRange, &range)!
        guard case .unavailable = AXFocusIdentityProvider.decodeSelectionRange(error: .success, value: axValue) else {
            return XCTFail("a negative-length selection must be unavailable (fail closed)")
        }
    }
}

// MARK: - Context split (overflow-safe, fail closed on malformed range)

final class ContextSplitTests: XCTestCase {

    func testNilRangeUsesWholeTextAsPrefix() {
        let split = ContextSplit.split("hello", range: nil)
        XCTAssertEqual(split?.prefix, "hello")
        XCTAssertEqual(split?.suffix, "")
    }

    func testValidCaretSplits() {
        let split = ContextSplit.split("hello", range: CFRange(location: 2, length: 0))
        XCTAssertEqual(split?.prefix, "he")
        XCTAssertEqual(split?.suffix, "llo")
    }

    func testValidSelectionOmitsSelectedText() {
        let split = ContextSplit.split("hello world", range: CFRange(location: 5, length: 1))
        XCTAssertEqual(split?.prefix, "hello")
        XCTAssertEqual(split?.suffix, "world")
    }

    func testNegativeLocationFailsClosed() {
        XCTAssertNil(ContextSplit.split("hello", range: CFRange(location: -1, length: 0)))
    }

    func testNegativeLengthFailsClosed() {
        XCTAssertNil(ContextSplit.split("hello", range: CFRange(location: 1, length: -1)))
    }

    func testOverflowingLocationPlusLengthFailsClosed() {
        XCTAssertNil(ContextSplit.split("hello", range: CFRange(location: Int.max, length: 1)))
    }

    func testCaretBeyondDocumentFailsClosed() {
        XCTAssertNil(ContextSplit.split("hello", range: CFRange(location: 100, length: 0)))
    }

    func testIntMaxLocationZeroLengthFailsClosed() {
        XCTAssertNil(ContextSplit.split("hello", range: CFRange(location: Int.max, length: 0)))
    }

    func testSelectionPastDocumentFailsClosed() {
        XCTAssertNil(ContextSplit.split("hello", range: CFRange(location: 4, length: 2)))
    }

    func testMalformedRangeOnEmptyDocumentFailsClosed() {
        XCTAssertNil(ContextSplit.split("", range: CFRange(location: 1, length: 0)))
    }
}

// MARK: - Direct AX inserter (pinned element, minimal-mutation selected-text)

/// Fake `AXEditorTextOps` that pins a session to the element focused at pin time
/// (`focusedElementLabel`, default "A"). A test can call `focusChanged(to:)` to
/// simulate the user switching focus; the session must remain bound to the pinned
/// element, so the write is never redirected to the newly focused element.
@MainActor
final class FakeAXEditorTextOps: AXEditorTextOps {
    let range: CFRange?
    let settable: Bool
    var setTextResult = true
    var setRangeResult = true
    /// When false, pin returns nil (simulating an element that cannot be proven
    /// to match the approved target) -> the inserter must fail closed, no write.
    var pinSucceeds = true
    /// Simulated current focus label; pin captures it into the session.
    var focusedElementLabel = "A"
    /// Writes recorded as (elementLabel, text) so a test can prove the PINNED
    /// element (not a focus-changed one) received the write.
    private(set) var writes: [(element: String, text: String)] = []
    private(set) var pinCalls = 0
    private(set) var lastSession: FakeAXEditorSession?

    init(range: CFRange?, settable: Bool) {
        self.range = range
        self.settable = settable
    }

    func pin(matching expected: FocusTarget) -> (any AXEditorSession)? {
        pinCalls += 1
        guard pinSucceeds else { return nil }
        let session = FakeAXEditorSession(
            ops: self, elementLabel: focusedElementLabel, range: range, settable: settable,
            setTextResult: setTextResult, setRangeResult: setRangeResult
        )
        lastSession = session
        return session
    }

    func focusChanged(to label: String) { focusedElementLabel = label }
    func recordWrite(_ text: String, to label: String) { writes.append((element: label, text: text)) }
}

@MainActor
final class FakeAXEditorSession: AXEditorSession {
    private let ops: FakeAXEditorTextOps
    let elementLabel: String
    let range: CFRange?
    let settable: Bool
    var setTextResult: Bool
    var setRangeResult: Bool
    var setText: String?
    var setRange: CFRange?
    private var rangeReads = 0

    init(ops: FakeAXEditorTextOps, elementLabel: String, range: CFRange?, settable: Bool, setTextResult: Bool, setRangeResult: Bool) {
        self.ops = ops
        self.elementLabel = elementLabel
        self.range = range
        self.settable = settable
        self.setTextResult = setTextResult
        self.setRangeResult = setRangeResult
    }

    func selectedRange() -> CFRange? {
        rangeReads += 1
        // Simulate the user switching focus right after the caret is read (i.e.
        // BETWEEN the range read and the write). With a pinned element this must
        // not redirect the write to the newly focused element.
        if rangeReads == 1 { ops.focusChanged(to: "B") }
        return range
    }

    func isSelectedTextSettable() -> Bool { settable }
    func setSelectedText(_ text: String) -> Bool {
        setText = text
        ops.recordWrite(text, to: elementLabel)
        return setTextResult
    }
    func setSelectedRange(_ newRange: CFRange) -> Bool { setRange = newRange; return setRangeResult }
}

@MainActor
final class AXDirectTextInserterTests: XCTestCase {

    /// A focused editor whose caret is at (5,0) and whose selection is settable.
    private func targetAt(_ location: Int, _ length: Int) -> FocusTarget {
        FocusTarget(
            appIdentifier: "com.a", windowIdentity: 1, elementIdentity: 1,
            selection: .range(FocusTarget.SelectionRange(location: location, length: length))
        )
    }

    private func makeInserter(_ ops: FakeAXEditorTextOps) -> AXDirectTextInserter {
        AXDirectTextInserter(ops: ops)
    }

    func testInsertsViaSelectedTextWhenSettable() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 5, length: 0), settable: true)
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0))
        XCTAssertEqual(result, .inserted)
        // Minimal mutation: sets the selected text, never the whole value.
        XCTAssertEqual(ops.lastSession?.setText, "hi")
        // Restores the caret after the inserted text (5 + 2 = 7).
        XCTAssertEqual(ops.lastSession?.setRange?.location, 7)
        XCTAssertEqual(ops.lastSession?.setRange?.length, 0)
    }

    func testFocusChangeAfterPinDoesNotRedirectWrite() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 5, length: 0), settable: true)
        // A focus change happens inside selectedRange() (to "B"); the write must
        // still target the PINNED element ("A"), not the newly focused one.
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0))
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(ops.writes.map(\.element), ["A"], "the write must go to the pinned element")
        XCTAssertFalse(ops.writes.contains(where: { $0.element == "B" }), "no different element may be mutated")
        XCTAssertEqual(ops.lastSession?.setText, "hi")
    }

    func testPinMismatchFailsClosedWithoutMutating() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 5, length: 0), settable: true)
        ops.pinSucceeds = false
        // The element cannot be proven to match the approved target: pin returns
        // nil and the inserter fails closed BEFORE any write.
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0))
        XCTAssertEqual(result, .unsupported)
        XCTAssertNil(ops.lastSession, "no session should be created on a pin mismatch")
        XCTAssertTrue(ops.writes.isEmpty, "no different element may be mutated when pin fails")
    }

    func testCaretMovedWithinPinnedElementAfterPinFailsClosed() {
        // The session is pinned (pin succeeds), but the caret moves within the SAME
        // element after pin: the freshly re-read range (9,0) no longer equals the
        // approved (5,0). The inserter must fail closed and write nothing.
        let ops = FakeAXEditorTextOps(range: CFRange(location: 9, length: 0), settable: true)
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0))
        XCTAssertEqual(result, .unsupported)
        XCTAssertNil(ops.lastSession?.setText, "must not insert at the moved caret")
        XCTAssertTrue(ops.writes.isEmpty, "no write may reach a moved caret")
    }

    func testFallsBackWhenSelectedTextNotSettable() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 5, length: 0), settable: false)
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0))
        XCTAssertEqual(result, .unsupported)
        XCTAssertNil(ops.lastSession?.setText, "must not mutate the editor when not settable")
    }

    func testFallsBackWhenNoRange() {
        let ops = FakeAXEditorTextOps(range: nil, settable: true)
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0))
        XCTAssertEqual(result, .unsupported)
        XCTAssertNil(ops.lastSession?.setText)
    }

    func testReportsFailedWhenSetFails() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 3, length: 0), settable: true)
        ops.setTextResult = false
        let result = makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(3, 0))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(ops.lastSession?.setText, "hi")
    }

    func testCaretRestoreIsBestEffortNotRequired() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 4, length: 0), settable: true)
        ops.setRangeResult = false
        let result = makeInserter(ops).insertDirect("x", appIdentifier: "com.a", focusTarget: targetAt(4, 0))
        // A failed caret move is not a failed insertion; text is committed.
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(ops.lastSession?.setText, "x")
    }

    func testNegativeRangeFallsBackWithoutMutating() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: -1, length: 0), settable: true)
        XCTAssertEqual(makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(5, 0)), .unsupported)
        XCTAssertNil(ops.lastSession?.setText, "must not mutate on a malformed (negative) range")
    }

    func testNegativeLengthFallsBackWithoutMutating() {
        let ops = FakeAXEditorTextOps(range: CFRange(location: 4, length: -1), settable: true)
        XCTAssertEqual(makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(4, 0)), .unsupported)
        XCTAssertNil(ops.lastSession?.setText, "must not mutate on a malformed (negative-length) range")
    }

    func testOverflowInsertionEndFallsBackWithoutMutating() {
        // An AX element can report an Int.max caret; location + text length
        // overflows and must fail closed before any setSelectedText.
        let ops = FakeAXEditorTextOps(range: CFRange(location: Int.max, length: 0), settable: true)
        XCTAssertEqual(makeInserter(ops).insertDirect("hi", appIdentifier: "com.a", focusTarget: targetAt(Int.max, 0)), .unsupported)
        XCTAssertNil(ops.lastSession?.setText)
    }
}

// MARK: - Clipboard serialization / restore policy

final class ClipboardSerializationTests: XCTestCase {

    func testRestoreOnlyWhenChangeCountUnchanged() {
        XCTAssertTrue(ClipboardRestorePolicy.shouldRestore(snapshotChangeCount: 7, currentChangeCount: 7))
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(snapshotChangeCount: 7, currentChangeCount: 12))
    }

    func testFileURLCarriedAsPropertyListRepresentation() {
        // A copied file exposes public.file-url as a property list (a URL
        // string), not raw Data. The snapshot must retain the propertyList.
        let item = ClipboardSnapshot.Item(
            types: ["public.file-url"],
            propertyListsByType: ["public.file-url": .string("file:///tmp/archive.zip")]
        )
        XCTAssertEqual(
            item.representation(for: "public.file-url"),
            .propertyList(.string("file:///tmp/archive.zip"))
        )
    }

    func testStringRepresentationPreferredForPlainText() {
        let item = ClipboardSnapshot.Item(
            types: ["public.utf8-plain-text"],
            stringByType: ["public.utf8-plain-text": "plain text"]
        )
        XCTAssertEqual(
            item.representation(for: "public.utf8-plain-text"),
            .string("plain text")
        )
    }

    func testMultipleFilesFilenamesArrayPreserved() {
        let item = ClipboardSnapshot.Item(
            types: ["public.filenames"],
            propertyListsByType: ["public.filenames": .array([.string("/tmp/a.txt"), .string("/tmp/b.txt")])]
        )
        let rep = item.representation(for: "public.filenames")
        // Represented as a property list so the array of paths is not flattened
        // into a single data blob.
        XCTAssertEqual(
            rep,
            .propertyList(.array([.string("/tmp/a.txt"), .string("/tmp/b.txt")]))
        )
    }

    func testFileURLStringRoundTripsThroughClipboardValue() {
        let url = "file:///home/user/Documents/report.pdf"
        guard let wrapped = ClipboardValue(value: url) else {
            return XCTFail("should wrap a URL string")
        }
        XCTAssertEqual(wrapped.anyValue as? String, url)
    }

    func testPropertyListRoundTripsThroughValue() {
        let original: [String: Any] = ["paths": ["/tmp/a", "/tmp/b"], "count": 2]
        guard let plist = ClipboardPropertyList(value: original) else {
            return XCTFail("should convert dict to ClipboardPropertyList")
        }
        let wrapped = ClipboardValue(value: plist.anyValue)
        XCTAssertEqual(wrapped, .propertyList(plist))
    }
}
