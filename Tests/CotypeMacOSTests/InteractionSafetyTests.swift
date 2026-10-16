import XCTest
import CotypeCore
@testable import CotypeMacOS

// MARK: - GlobalKeyRouter (shortcut modifier routing)

final class GlobalKeyRouterTests: XCTestCase {

    private func router(shortcut: TriggerShortcut = .default) -> GlobalKeyRouter {
        // Stub layout: a fixed keyCode->base map so tests are deterministic.
        GlobalKeyRouter(trigger: shortcut) { keyCode in
            switch keyCode {
            case 47: return "."
            case 44: return "/"
            case 42: return "\\"
            case 5: return "g"
            default: return nil
            }
        }
    }

    func testUnmodifiedTabAcceptsNextWordWhenReady() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .acceptWord
        )
    }

    func testOptionTabAcceptsAllWhenReady() {
        let r = router()
        // Default full-suggestion chord is Option+Tab.
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(option: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .acceptAll
        )
    }

    func testOptionTabPassesThroughWhenNotReady() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(option: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
    }

    func testOptionTabWithExtraMetaPassesThrough() {
        let r = router()
        // Accept-all is exactly [.option]; extra Control/Shift/Command do not match.
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(control: true, option: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .passthrough
        )
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(option: true, shift: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .passthrough
        )
    }

    func testCommandOptionTabNeverHijacked() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(command: true, option: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .passthrough
        )
    }

    func testCustomAcceptAllModifiers() {
        // A user-configured accept-all chord (e.g. Control+Tab) routes correctly.
        let r = GlobalKeyRouter(trigger: .default, acceptAll: AcceptAllShortcut(modifiers: [.control])) { keyCode in
            keyCode == 48 ? "\t" : nil
        }
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(control: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .acceptAll
        )
        // Unmodified Tab still accepts the next word even with a custom accept-all.
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .acceptWord
        )
    }

    func testShiftTabIsNeverHijacked() {
        let r = router()
        // Shift+Tab must pass through as outdent/navigation, even when ready.
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(shift: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .passthrough
        )
    }

    func testCommandTabPassesThroughEvenWhenReady() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(command: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: true, isRepeat: false),
            .passthrough
        )
    }

    func testTabNotConsumedWhenNotReady() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
    }

    func testEscapeCancelsOnlyWhenActiveAndNoReservedMeta() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 53, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: true, isAcceptReady: false, isRepeat: false),
            .cancel
        )
        // Command+Escape passes through.
        XCTAssertEqual(
            r.route(keyCode: 53, modifiers: KeyModifiers(command: true), isSelfActive: false,
                    isCompletionActive: true, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
        // Escape with no active completion passes through.
        XCTAssertEqual(
            r.route(keyCode: 53, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
    }

    func testTriggerMatchesExactModifierChordAndLayout() {
        // Shortcut = Control + "." ; current layout resolves key 47 -> ".".
        let r = router(shortcut: TriggerShortcut(modifiers: [.control], key: "."))
        XCTAssertEqual(
            r.route(keyCode: 47, modifiers: KeyModifiers(control: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .trigger
        )
        // No modifier -> no trigger.
        XCTAssertEqual(
            r.route(keyCode: 47, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
        // Extra modifier (Command) -> no trigger, passes through.
        XCTAssertEqual(
            r.route(keyCode: 47, modifiers: KeyModifiers(command: true, control: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
    }

    func testCommandTriggerAlwaysPassesThrough() {
        let r = router(shortcut: TriggerShortcut(modifiers: [.command], key: "."))
        XCTAssertEqual(
            r.route(keyCode: 47, modifiers: KeyModifiers(command: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
    }

    func testTriggerRepeatConsumesOnlyWhenInitialWasHandled() {
        let r = router(shortcut: TriggerShortcut(modifiers: [.control], key: "."))
        // Repeat of a trigger that WAS consumed: swallow, do not re-generate.
        XCTAssertEqual(
            r.route(keyCode: 47, modifiers: KeyModifiers(control: true), isSelfActive: false,
                    isCompletionActive: true, isAcceptReady: false, isRepeat: true,
                    triggerHandled: true),
            .triggerRepeat
        )
        // Repeat of a trigger that was NOT consumed (gated & passed through):
        // pass through — no repeated gating attempt.
        XCTAssertEqual(
            r.route(keyCode: 47, modifiers: KeyModifiers(control: true), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: true,
                    triggerHandled: false),
            .passthrough
        )
    }

    func testSelfActiveAlwaysPassesThrough() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 48, modifiers: KeyModifiers(), isSelfActive: true,
                    isCompletionActive: true, isAcceptReady: true, isRepeat: false),
            .passthrough
        )
    }

    func testTriggerPreservesPassThroughForUnmatchedKeys() {
        let r = router()
        XCTAssertEqual(
            r.route(keyCode: 5, modifiers: KeyModifiers(), isSelfActive: false,
                    isCompletionActive: false, isAcceptReady: false, isRepeat: false),
            .passthrough
        )
    }
}

// MARK: - ClipboardRestorePolicy

final class ClipboardPolicyTests: XCTestCase {
    func testRestoresOnlyWhenChangeCountUnchanged() {
        XCTAssertTrue(ClipboardRestorePolicy.shouldRestore(snapshotChangeCount: 5, currentChangeCount: 5))
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(snapshotChangeCount: 5, currentChangeCount: 9))
    }
}

// MARK: - FocusGuardPolicy

final class FocusGuardPolicyTests: XCTestCase {
    func testCancelsWhenFrontmostAppChanges() {
        XCTAssertTrue(FocusGuardPolicy.shouldCancelPending(activeAppIdentifier: "com.a", currentFrontmost: "com.b"))
        XCTAssertTrue(FocusGuardPolicy.shouldCancelPending(activeAppIdentifier: "unknown", currentFrontmost: "com.a"))
    }
    func testKeepsWhenSameApp() {
        XCTAssertFalse(FocusGuardPolicy.shouldCancelPending(activeAppIdentifier: "com.a", currentFrontmost: "com.a"))
    }
}

// MARK: - CompletionFlow (controller phases / stale callbacks)

final class CompletionFlowTests: XCTestCase {
    func testBeginGenerationTransitionsToGeneratingAndReturnsToken() {
        var flow = CompletionFlow()
        let id = flow.beginGeneration()
        XCTAssertEqual(flow.phase, .generating)
        XCTAssertTrue(flow.isCurrent(id))
        XCTAssertTrue(flow.isGenerating)
    }

    func testCandidateReadyTransitionsToAwaitingAccept() {
        var flow = CompletionFlow()
        _ = flow.beginGeneration()
        flow.candidateReady()
        XCTAssertEqual(flow.phase, .awaitingAccept)
        XCTAssertTrue(flow.isAwaitingAccept)
    }

    func testStaleGenerationIsRejected() {
        var flow = CompletionFlow()
        let id1 = flow.beginGeneration()
        // Superseding trigger begins a new generation.
        let id2 = flow.beginGeneration()
        XCTAssertFalse(flow.isCurrent(id1))
        XCTAssertTrue(flow.isCurrent(id2))
    }

    func testCancelInvalidatesGeneration() {
        var flow = CompletionFlow()
        let id = flow.beginGeneration()
        flow.cancel()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertFalse(flow.isCurrent(id))
        XCTAssertFalse(flow.isActive)
    }

    func testAcceptInvalidatesGenerationAndReturnsIdle() {
        var flow = CompletionFlow()
        let id = flow.beginGeneration()
        flow.candidateReady()
        flow.accept()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertFalse(flow.isCurrent(id))
    }

    func testFinishWithoutCandidateReturnsIdleWithoutWaiting() {
        var flow = CompletionFlow()
        let id = flow.beginGeneration()
        flow.finishWithoutCandidate()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertFalse(flow.isCurrent(id))
    }
}

// MARK: - EngineLifecycle (load/unload waits and races)

final class EngineLifecycleTests: XCTestCase {
    func testBeginLoadStartsOnlyOnce() {
        var lc = EngineLifecycle()
        XCTAssertTrue(lc.beginLoad())
        XCTAssertEqual(lc.status, .loading)
        // Second load while loading is a no-op.
        XCTAssertFalse(lc.beginLoad())
    }

    func testFinishLoadReadySetsLoaded() {
        var lc = EngineLifecycle()
        _ = lc.beginLoad()
        lc.finishLoad(success: true)
        XCTAssertEqual(lc.status, .ready)
        XCTAssertTrue(lc.hasLoadedEngine)
        XCTAssertFalse(lc.beginLoad()) // loaded -> no-op
    }

    func testUnloadRefusesWhenBusy() {
        var lc = EngineLifecycle()
        _ = lc.beginLoad()
        lc.finishLoad(success: true)
        XCTAssertFalse(lc.unload(allow: false)) // busy -> refuse
        XCTAssertEqual(lc.status, .ready)        // still loaded
        XCTAssertTrue(lc.unload(allow: true))
        XCTAssertEqual(lc.status, .idle)
        XCTAssertFalse(lc.hasLoadedEngine)
    }

    func testUnloadBumpsVersionInvalidatingWaiters() {
        var lc = EngineLifecycle()
        _ = lc.beginLoad()
        let v1 = lc.loadVersion
        _ = lc.unload(allow: true)
        XCTAssertGreaterThan(lc.loadVersion, v1)
        XCTAssertTrue(lc.isStale(v1))
    }

    func testWaiterBookkeeping() {
        var lc = EngineLifecycle()
        lc.addWaiter()
        lc.addWaiter()
        XCTAssertEqual(lc.waiterCount, 2)
        lc.setWaiters(0)
        XCTAssertEqual(lc.waiterCount, 0)
    }
}

// MARK: - TriggerShortcut

final class TriggerShortcutTests: XCTestCase {
    func testDefaultIsControlPeriod() {
        XCTAssertEqual(TriggerShortcut.default.modifiers, [.control])
        XCTAssertEqual(TriggerShortcut.default.key, ".")
    }
    func testCommandShortcutIsReservedForSystem() {
        XCTAssertTrue(TriggerShortcut(modifiers: [.command], key: "p").isReservedForSystem)
        XCTAssertFalse(TriggerShortcut(modifiers: [.control], key: "p").isReservedForSystem)
    }
    func testDisplayString() {
        XCTAssertEqual(TriggerShortcut(modifiers: [.control], key: ".").displayString, "⌃.")
    }
    func testStoreRoundTrips() {
        let defaults = makeUserDefaults()
        let s = TriggerShortcut(modifiers: [.option, .shift], key: "/")
        TriggerShortcutStore.save(s, userDefaults: defaults)
        XCTAssertEqual(TriggerShortcutStore.load(userDefaults: defaults), s)
    }
    func testStoreDefaultsWhenEmpty() {
        let defaults = makeUserDefaults()
        XCTAssertEqual(TriggerShortcutStore.load(userDefaults: defaults), .default)
    }
    func testStoreRejectsCommandShortcut() throws {
        let defaults = makeUserDefaults()
        let command = TriggerShortcut(modifiers: [.command], key: "p")
        TriggerShortcutStore.save(command, userDefaults: defaults)
        XCTAssertEqual(TriggerShortcutStore.load(userDefaults: defaults), .default)

        // Also protect against a reserved value written by an older build.
        defaults.set(try JSONEncoder().encode(command), forKey: TriggerShortcutStore.defaultsKey)
        XCTAssertEqual(TriggerShortcutStore.load(userDefaults: defaults), .default)
    }

    func testKeyboardLayoutResolverProducesBaseKeys() {
        // The active layout always maps at least a handful of keys; this guards
        // the UCKeyTranslate plumbing (returns a real char, not empty).
        let baseKeys = KeyboardLayoutResolver.allBaseKeys()
        XCTAssertFalse(baseKeys.isEmpty)
        XCTAssertTrue(baseKeys.contains { !$0.value.isEmpty })
    }
}

// MARK: - AcceptAllShortcut

final class AcceptAllShortcutTests: XCTestCase {
    func testDefaultIsOptionTab() {
        let acceptable = AcceptAllShortcut.default
        XCTAssertEqual(acceptable.modifiers, [.option])
        XCTAssertEqual(acceptable.displayString, "⌥Tab")
    }

    func testCommandShortcutIsInvalidAndReserved() {
        let command = AcceptAllShortcut(modifiers: [.command])
        XCTAssertTrue(command.isReservedForSystem)
        XCTAssertFalse(command.isValid)
        XCTAssertTrue(AcceptAllShortcut.default.isValid)
    }

    func testStoreRoundTrips() {
        let defaults = makeUserDefaults()
        let s = AcceptAllShortcut(modifiers: [.control])
        AcceptAllShortcutStore.save(s, userDefaults: defaults)
        XCTAssertEqual(AcceptAllShortcutStore.load(userDefaults: defaults), s)
    }

    func testStoreFallsBackToDefaultForInvalid() throws {
        let defaults = makeUserDefaults()
        // Command chords are never accepted and cannot be persisted.
        let command = AcceptAllShortcut(modifiers: [.command])
        AcceptAllShortcutStore.save(command, userDefaults: defaults)
        XCTAssertEqual(AcceptAllShortcutStore.load(userDefaults: defaults), .default)

        // Also guard against a reserved value written by an older build.
        defaults.set(try JSONEncoder().encode(command), forKey: AcceptAllShortcutStore.defaultsKey)
        XCTAssertEqual(AcceptAllShortcutStore.load(userDefaults: defaults), .default)
    }
}

// MARK: - Typing observation (never consume normal typing)

final class TypingObservationTests: XCTestCase {
    func testOrdinaryLettersAndSpaceAreObserved() {
        XCTAssertTrue(isOrdinaryTypingText("a", hasReservedMeta: false))
        XCTAssertTrue(isOrdinaryTypingText("A", hasReservedMeta: false))
        XCTAssertTrue(isOrdinaryTypingText(" ", hasReservedMeta: false))
        XCTAssertTrue(isOrdinaryTypingText(".", hasReservedMeta: false))
    }

    func testReservedMetaNeverObserved() {
        XCTAssertFalse(isOrdinaryTypingText("a", hasReservedMeta: true))
        XCTAssertFalse(isOrdinaryTypingText("", hasReservedMeta: false))
    }

    func testControlAndFunctionKeysNeverObserved() {
        XCTAssertFalse(isOrdinaryTypingText("\t", hasReservedMeta: false))
        XCTAssertFalse(isOrdinaryTypingText("\n", hasReservedMeta: false))
        // Apple function/private-use range (e.g. arrows).
        XCTAssertFalse(isOrdinaryTypingText(String(UnicodeScalar(0xF700)!), hasReservedMeta: false))
    }

    func testMultiCharacterPasteIsNotSingleTyping() {
        XCTAssertFalse(isOrdinaryTypingText("hello", hasReservedMeta: false))
    }
}

// MARK: - Editor observation (deferred pass-through edit classification)

final class EditorObservationTests: XCTestCase {
    func testPrintableTypingIsObserved() {
        XCTAssertEqual(
            classifyEditorObservation(keyCode: 0, modifiers: KeyModifiers(), text: "a"),
            .typed("a")
        )
        XCTAssertEqual(
            classifyEditorObservation(keyCode: 49, modifiers: KeyModifiers(shift: true), text: "A"),
            .typed("A")
        )
        XCTAssertEqual(
            classifyEditorObservation(keyCode: 49, modifiers: KeyModifiers(), text: " "),
            .typed(" ")
        )
    }

    func testBackspaceDeleteReturnTabAreMutations() {
        // Backspace (51), Forward Delete (117), Return (36), keypad Enter (76),
        // unmodified Tab (48).
        for (code, modifiers) in [
            (51, KeyModifiers()),
            (117, KeyModifiers()),
            (36, KeyModifiers()),
            (76, KeyModifiers()),
            (48, KeyModifiers()),
        ] as [(UInt16, KeyModifiers)] {
            XCTAssertEqual(
                classifyEditorObservation(keyCode: code, modifiers: modifiers, text: ""),
                .mutated,
                "key \(code) should be a mutation"
            )
        }
    }

    func testMutatingCommandChordsAreObservedNotHijacked() {
        // Paste (Cmd+V = 9), Cut (Cmd+X = 7), Undo/Redo (Cmd+Z = 6).
        for code in [9, 7, 6] as [UInt16] {
            XCTAssertEqual(
                classifyEditorObservation(keyCode: code, modifiers: KeyModifiers(command: true), text: ""),
                .mutated
            )
        }
        // A non-mutating Command chord (e.g. Cmd+C copy = 8) is not observed.
        XCTAssertNil(
            classifyEditorObservation(keyCode: 8, modifiers: KeyModifiers(command: true), text: "")
        )
    }

    func testShiftTabIsNeverObserved() {
        // Shift+Tab is outdent/navigation, not an edit mutation.
        XCTAssertNil(
            classifyEditorObservation(keyCode: 48, modifiers: KeyModifiers(shift: true), text: "")
        )
        XCTAssertEqual(
            classifyEditorObservation(keyCode: 48, modifiers: KeyModifiers(), text: ""),
            .mutated
        )
    }

    func testNavigationsAreObservedAsMutations() {
        // Arrows / Home / End / Page Up / Down move the caret within the field
        // and must invalidate a stale ghost.
        for code in [115, 119, 116, 121, 123, 124, 125, 126] as [UInt16] {
            XCTAssertEqual(
                classifyEditorObservation(keyCode: code, modifiers: KeyModifiers(), text: ""),
                .mutated,
                "key \(code) should be a caret-move mutation"
            )
        }
    }

    func testNonMutatingKeysAreNotObserved() {
        // A function key (F1 = 122) and bare modifier chords are not ordinary edits.
        XCTAssertNil(
            classifyEditorObservation(keyCode: 122, modifiers: KeyModifiers(), text: "")
        )
        XCTAssertNil(
            classifyEditorObservation(keyCode: 0, modifiers: KeyModifiers(control: true), text: "a")
        )
        XCTAssertNil(
            classifyEditorObservation(keyCode: 0, modifiers: KeyModifiers(option: true), text: "a")
        )
    }
}
