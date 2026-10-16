import XCTest
@testable import CotypeMacOS

// MARK: - CompletionInteraction (manual-first)

/// Behavior tests for the manual-first interaction state machine. These drive the
/// pure seam directly (no AppKit, no timers) and assert the state + effects:
/// only an explicit `.manualTrigger` starts a generation, any typing/editing/
/// pointer change while generating or showing a candidate cancels/dismisses and
/// returns to idle, and manual trigger / Tab / Option-Tab / Escape all still work.
final class CompletionInteractionTests: XCTestCase {

    // MARK: - Idle input never arms the debounce

    func testTypingInIdleDoesNotArmDebounce() {
        var m = CompletionInteraction()
        let effects = m.handle(.typed("h"))
        XCTAssertEqual(m.state, .idle, "manual-first: typing must not start the pause timer")
        XCTAssertEqual(effects, [.none])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testEditedInIdleDoesNotArmDebounce() {
        var m = CompletionInteraction()
        let effects = m.handle(.edited)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.none])
    }

    func testContextMovedInIdleDoesNotArmDebounce() {
        var m = CompletionInteraction()
        let effects = m.handle(.contextMoved)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.none])
    }

    func testDebounceElapsedNeverGeneratesWithoutAManualTrigger() {
        var m = CompletionInteraction()
        _ = m.handle(.typed("h"))
        let effects = m.handle(.debounceElapsed)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.none], "a stray timer must not start a generation")
    }

    // MARK: - Manual force-trigger

    func testManualTriggerFromIdleBeginsGeneration() {
        var m = CompletionInteraction()
        let effects = m.handle(.manualTrigger)
        XCTAssertEqual(m.state, .generating)
        XCTAssertEqual(effects, [.beginGeneration(.manual)])
    }

    func testManualTriggerDuringGeneratingSupersedes() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.manualTrigger)
        XCTAssertEqual(m.state, .generating)
        XCTAssertEqual(effects, [.cancelGeneration, .beginGeneration(.manual)])
    }

    func testManualTriggerDuringCooldownOverrides() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.dismissed)         // cooldown
        XCTAssertEqual(m.state, .cooldown)
        let effects = m.handle(.manualTrigger)
        XCTAssertEqual(m.state, .generating)
        XCTAssertEqual(effects, [.beginGeneration(.manual)])
    }

    func testManualTriggerWhileAwaitingDropsCurrentGhost() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello")) // awaitingAccept
        let effects = m.handle(.manualTrigger)
        XCTAssertEqual(m.state, .generating)
        XCTAssertEqual(effects, [.cancelGeneration, .beginGeneration(.manual)])
        XCTAssertTrue(m.ghost.isEmpty, "previous ghost is dropped on re-trigger")
    }

    // MARK: - Streaming and candidate arrival

    func testStreamedUpdatesGhostOnlyWhileGenerating() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.streamed("ello"))
        XCTAssertEqual(m.state, .generating)
        XCTAssertEqual(m.ghost, "ello")
    }

    func testStreamedIgnoredWhenIdle() {
        var m = CompletionInteraction()
        // A stray streamed event with no active generation must not mutate state.
        let effects = m.handle(.streamed("stale"))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.none])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testGeneratedTransitionsToAwaitingAccept() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.generated("ello world"))
        XCTAssertEqual(m.state, .awaitingAccept)
        XCTAssertEqual(m.ghost, "ello world")
        XCTAssertEqual(effects, [.none])
    }

    func testGeneratedIgnoredWhenNoGenerationIsRunning() {
        var m = CompletionInteraction()
        let effects = m.handle(.generated("ello"))
        XCTAssertEqual(m.state, .idle, "a stale candidate must not resurrect a suggestion")
        XCTAssertEqual(effects, [.none])
    }

    func testNoSuggestionReturnsToIdle() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.noSuggestion)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.ghost.isEmpty)
        XCTAssertEqual(effects, [.none])
    }

    // MARK: - Edits while generating cancel and return idle (no regeneration)

    func testTypingWhileGeneratingCancelsToIdle() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.typed("i"))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testEditedWhileGeneratingCancelsToIdle() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.edited)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testContextMovedWhileGeneratingCancelsToIdle() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.contextMoved)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    // MARK: - Edits while a candidate is showing dismiss it

    func testTypingWhileAwaitingDismissesWithoutTypeThrough() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello world"))
        // Even a matching character dismisses in manual-first mode: only Tab and
        // the accept-all chord insert, and nothing regenerates automatically.
        let effects = m.handle(.typed("e"))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testEditedWhileAwaitingDismissesStaleGhost() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello"))
        let effects = m.handle(.edited)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty, "a non-char edit must invalidate the stale ghost")
    }

    func testContextMovedWhileAwaitingDismissesStaleGhost() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello"))
        let effects = m.handle(.contextMoved)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    // MARK: - Accept next word (stepping) / accept all

    func testAcceptNextWordCommitsOnlyFirstWordKeepsRest() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated(" world peace"))
        let effects = m.handle(.acceptNextWord)
        XCTAssertEqual(effects, [.commit(" world ")])
        XCTAssertEqual(m.state, .awaitingAccept, "remaining ghost still awaiting")
        XCTAssertEqual(m.ghost, "peace")
    }

    func testAcceptNextWordOnSingleWordGoesIdle() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("world"))
        let effects = m.handle(.acceptNextWord)
        XCTAssertEqual(effects, [.commit("world")])
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testAcceptNextWordWhenNotReadyIsIgnored() {
        var m = CompletionInteraction()
        let effects = m.handle(.acceptNextWord)
        XCTAssertEqual(effects, [.none])
        XCTAssertEqual(m.state, .idle)
    }

    func testAcceptAllCommitsWholeGhostAndGoesIdle() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("hello world"))
        let effects = m.handle(.acceptAll)
        XCTAssertEqual(effects, [.commit("hello world")])
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testAcceptAllWhenNotReadyIsIgnored() {
        var m = CompletionInteraction()
        let effects = m.handle(.acceptAll)
        XCTAssertEqual(effects, [.none])
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - Escape dismiss + brief cooldown

    func testEscapeDuringGenerationCancelsAndStartsCooldown() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.dismissed)
        XCTAssertEqual(m.state, .cooldown)
        XCTAssertEqual(effects, [.cancelGeneration, .startCooldown])
    }

    func testEscapeDuringAwaitingDismissesGhostAndStartsCooldown() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("hello"))
        let effects = m.handle(.dismissed)
        XCTAssertEqual(m.state, .cooldown)
        XCTAssertEqual(effects, [.startCooldown])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testEscapeInIdleIsIgnored() {
        var m = CompletionInteraction()
        let effects = m.handle(.dismissed)
        XCTAssertEqual(effects, [.none])
        XCTAssertEqual(m.state, .idle)
    }

    func testCooldownExpiryAfterEditsGoesIdleWithoutDebounce() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.dismissed)         // cooldown
        XCTAssertEqual(m.state, .cooldown)

        XCTAssertEqual(m.handle(.typed("x")), [.none])
        XCTAssertEqual(m.state, .cooldown, "edits must not break the dismissal")
        XCTAssertEqual(m.handle(.contextMoved), [.none])
        XCTAssertEqual(m.state, .cooldown)

        let resume = m.handle(.cooldownElapsed)
        XCTAssertEqual(m.state, .idle, "manual-first never resumes auto-generation")
        XCTAssertEqual(resume, [.none])
    }

    // MARK: - Full manual loop

    func testManualLoopTriggerStreamAcceptAll() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.streamed("ello "))
        _ = m.handle(.generated("ello world"))
        XCTAssertEqual(m.state, .awaitingAccept)
        let effects = m.handle(.acceptAll)
        XCTAssertEqual(effects, [.commit("ello world")])
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testManualLoopTypeThroughIsDismissedNotInserted() {
        var m = CompletionInteraction()
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello world"))
        for ch in "ello" {
            let effects = m.handle(.typed(String(ch)))
            let committed = effects.contains { if case .commit = $0 { return true } else { return false } }
            XCTAssertFalse(committed, "type-through must never insert")
        }
        XCTAssertEqual(m.state, .idle, "typing dismisses the candidate in manual-first mode")
    }

    // MARK: - nextWordSegment helper

    func testNextWordSegmentWithLeadingSpace() {
        XCTAssertEqual(CompletionInteraction.nextWordSegment(" world peace"), " world ")
    }

    func testNextWordSegmentWithoutLeadingSpace() {
        XCTAssertEqual(CompletionInteraction.nextWordSegment("world peace"), "world ")
    }

    func testNextWordSegmentSingleWord() {
        XCTAssertEqual(CompletionInteraction.nextWordSegment("world"), "world")
    }

    func testNextWordSegmentOnlyWhitespace() {
        XCTAssertEqual(CompletionInteraction.nextWordSegment("  "), "  ")
    }

    func testNextWordSegmentMultipleWhitespaceBetweenWords() {
        XCTAssertEqual(CompletionInteraction.nextWordSegment("world   peace"), "world   ")
    }

    // MARK: - consumeLeadingMatch helper

    func testConsumeLeadingMatch() {
        XCTAssertEqual(CompletionInteraction.consumeLeadingMatch(ghost: "hello world", typed: "hel"), "lo world")
        XCTAssertEqual(CompletionInteraction.consumeLeadingMatch(ghost: "hello", typed: "hello"), "")
        XCTAssertNil(CompletionInteraction.consumeLeadingMatch(ghost: "hello", typed: "help"))
    }
}

// MARK: - Opt-in automatic lane

/// The future automatic-suggestion seam is off by default and only reachable by
/// constructing the machine with `autoSuggestEnabled: true`. These tests keep that
/// lane honest without exposing any of it in the app.
final class CompletionInteractionAutoSuggestTests: XCTestCase {

    func testAutoDisabledByDefault() {
        XCTAssertFalse(CompletionInteraction().autoSuggestEnabled)
    }

    func testTypingInIdleDebounces() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        let effects = m.handle(.typed("h"))
        XCTAssertEqual(m.state, .debouncing)
        XCTAssertEqual(effects, [.startDebounce])
    }

    func testDebounceElapsedBeginsAutoGeneration() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.typed("h"))
        let effects = m.handle(.debounceElapsed)
        XCTAssertEqual(m.state, .generating)
        XCTAssertEqual(effects, [.beginGeneration(.debounce)])
    }

    func testTypingWhileGeneratingRebounces() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.typed("i"))
        XCTAssertEqual(m.state, .debouncing)
        XCTAssertEqual(effects, [.cancelGeneration, .startDebounce])
    }

    func testEditedWhileGeneratingRebounces() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.edited)
        XCTAssertEqual(m.state, .debouncing)
        XCTAssertEqual(effects, [.cancelGeneration, .startDebounce])
    }

    func testTypedMatchConsumesGhostLeadingCharacters() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello world"))
        let effects = m.handle(.typed("e"))
        XCTAssertEqual(m.state, .awaitingAccept, "still accepting while matching")
        XCTAssertEqual(m.ghost, "llo world")
        XCTAssertEqual(effects, [.none])
    }

    func testTypedMatchThroughWholeGhostDebouncesForNext() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello"))
        let effects = m.handle(.typed("ello"))
        XCTAssertEqual(m.state, .debouncing, "fully typed through -> regenerate next")
        XCTAssertEqual(effects, [.startDebounce])
    }

    func testTypedMismatchDismissesAndRegenerates() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello world"))
        let effects = m.handle(.typed("x"))
        XCTAssertEqual(m.state, .debouncing)
        XCTAssertEqual(effects, [.cancelGeneration, .startDebounce])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testCooldownResumesAfterEdits() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        _ = m.handle(.dismissed)
        XCTAssertEqual(m.handle(.typed("x")), [.none])
        let resume = m.handle(.cooldownElapsed)
        XCTAssertEqual(m.state, .debouncing)
        XCTAssertEqual(resume, [.startDebounce])
    }

    // MARK: - A pointer/navigation change never arms the debounce

    func testContextMovedInIdleNeverArmsDebounce() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        let effects = m.handle(.contextMoved)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.none], "a mouse click is not typing and must not schedule auto-suggest")
    }

    func testContextMovedWhileGeneratingCancelsToIdle() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        let effects = m.handle(.contextMoved)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
    }

    func testContextMovedWhileAwaitingDismissesToIdle() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        _ = m.handle(.generated("ello"))
        let effects = m.handle(.contextMoved)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effects, [.cancelGeneration])
        XCTAssertTrue(m.ghost.isEmpty)
    }

    func testContextMovedDuringCooldownDoesNotResumeOnExpiry() {
        var m = CompletionInteraction(autoSuggestEnabled: true)
        _ = m.handle(.manualTrigger)
        _ = m.handle(.dismissed)
        XCTAssertEqual(m.handle(.contextMoved), [.none])
        let resume = m.handle(.cooldownElapsed)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(resume, [.none])
    }
}
