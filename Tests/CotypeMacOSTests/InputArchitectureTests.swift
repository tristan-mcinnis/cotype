import XCTest
import CoreGraphics
import Carbon
@testable import CotypeMacOS

// MARK: - Manual trigger: Carbon hot-key registration (pure)

/// The manual trigger is a *registered* chord, so it is resolved to a virtual
/// key code plus a Carbon modifier mask before `RegisterEventHotKey` runs. All
/// of that is pure and injected here, so the plan is testable without a live
/// keyboard layout or a live registration.
final class TriggerHotKeyRegistrationTests: XCTestCase {

    func testPlanResolvesTheLowestKeyCodeForTheTriggerCharacter() {
        // Two physical keys produce "." in a hypothetical layout; the plan picks
        // the lowest key code so registration is deterministic.
        let plan = TriggerHotKeyRegistration.plan(
            for: TriggerShortcut(modifiers: [.control], key: "."),
            keyCodes: { _ in [47, 44] }
        )
        XCTAssertEqual(plan, CarbonHotKeyPlan(keyCode: 44, carbonModifiers: UInt32(controlKey)))
    }

    func testPlanCarriesEveryModifierIntoTheCarbonMask() {
        let plan = TriggerHotKeyRegistration.plan(
            for: TriggerShortcut(modifiers: [.control, .option, .shift], key: "/"),
            keyCodes: { _ in [44] }
        )
        XCTAssertEqual(plan?.keyCode, 44)
        XCTAssertEqual(
            plan?.carbonModifiers,
            UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey)
        )
    }

    func testCommandChordsAreNeverRegistered() {
        // Command belongs to the host app or macOS and must never be reserved.
        XCTAssertNil(TriggerHotKeyRegistration.plan(
            for: TriggerShortcut(modifiers: [.command], key: "p"),
            keyCodes: { _ in [35] }
        ))
        XCTAssertNil(TriggerHotKeyRegistration.plan(
            for: TriggerShortcut(modifiers: [.command, .control], key: "."),
            keyCodes: { _ in [47] }
        ))
    }

    func testModifierlessTriggerIsNotRegisterable() {
        XCTAssertNil(TriggerHotKeyRegistration.plan(
            for: TriggerShortcut(modifiers: [], key: "."),
            keyCodes: { _ in [47] }
        ))
    }

    func testPlanReturnsNilWhenTheLayoutHasNoKeyForTheCharacter() {
        XCTAssertNil(TriggerHotKeyRegistration.plan(
            for: TriggerShortcut(modifiers: [.control], key: "€"),
            keyCodes: { _ in [] }
        ))
    }

    func testTheDefaultTriggerResolvesAgainstTheLiveLayout() {
        // The shipped default chord must be registerable on a real Mac.
        XCTAssertNotNil(TriggerHotKeyRegistration.plan(for: .default))
    }

    func testCarbonMaskOfTheDefaultTrigger() {
        XCTAssertEqual(ShortcutModifiers([.control]).carbonHotKeyModifiers, UInt32(controlKey))
        XCTAssertEqual(ShortcutModifiers([]).carbonHotKeyModifiers, 0)
        XCTAssertEqual(ShortcutModifiers([.command]).carbonHotKeyModifiers, UInt32(cmdKey))
    }
}

// MARK: - Two-path lifecycle (pure)

final class GlobalInputLifecycleTests: XCTestCase {

    func testEnabledCotypeAlwaysWatchesTypingAndClicks() {
        // The listen-only observer is the automatic lane's input: it stays on
        // whenever completions are enabled, in every phase.
        for selfActive in [true, false] {
            for active in [true, false] {
                let plan = GlobalInputLifecycle.plan(
                    isSelfActive: selfActive, isCompletionActive: active, completionsEnabled: true
                )
                XCTAssertTrue(plan.installsTypingObserver, "selfActive=\(selfActive) active=\(active)")
                XCTAssertTrue(plan.monitorsClicks, "selfActive=\(selfActive) active=\(active)")
            }
        }
    }

    func testTheActiveTapExistsOnlyWhileACompletionIsLive() {
        XCTAssertTrue(GlobalInputLifecycle.plan(
            isSelfActive: false, isCompletionActive: true, completionsEnabled: true
        ).installsInteractionTap)
        XCTAssertFalse(GlobalInputLifecycle.plan(
            isSelfActive: false, isCompletionActive: false, completionsEnabled: true
        ).installsInteractionTap)
    }

    func testTheActiveTapIsNeverInstalledWhileCotypeOwnsTheKeyboard() {
        XCTAssertFalse(GlobalInputLifecycle.plan(
            isSelfActive: true, isCompletionActive: true, completionsEnabled: true
        ).installsInteractionTap)
    }

    func testTheTriggerHotKeyStaysRegisteredAsAFallback() {
        // Registered whenever Cotype is enabled and its own window is not key —
        // including during a live interaction, where the active tap forwards the
        // chord to it.
        XCTAssertTrue(GlobalInputLifecycle.plan(
            isSelfActive: false, isCompletionActive: true, completionsEnabled: true
        ).registersTriggerHotKey)
        XCTAssertTrue(GlobalInputLifecycle.plan(
            isSelfActive: false, isCompletionActive: false, completionsEnabled: true
        ).registersTriggerHotKey)
        XCTAssertFalse(GlobalInputLifecycle.plan(
            isSelfActive: true, isCompletionActive: true, completionsEnabled: true
        ).registersTriggerHotKey)
    }

    func testDisabledCompletionsInstallNothing() {
        for selfActive in [true, false] {
            for active in [true, false] {
                let plan = GlobalInputLifecycle.plan(
                    isSelfActive: selfActive, isCompletionActive: active, completionsEnabled: false
                )
                XCTAssertFalse(plan.installsTypingObserver, "selfActive=\(selfActive) active=\(active)")
                XCTAssertFalse(plan.registersTriggerHotKey)
                XCTAssertFalse(plan.installsInteractionTap)
                XCTAssertFalse(plan.monitorsClicks)
            }
        }
    }

    func testPlanAndInteractionPredicateAgree() {
        for selfActive in [true, false] {
            for active in [true, false] {
                XCTAssertEqual(
                    GlobalInputLifecycle.plan(
                        isSelfActive: selfActive, isCompletionActive: active, completionsEnabled: true
                    ).installsInteractionTap,
                    InteractionTapLifecycle.shouldInstall(isSelfActive: selfActive, isCompletionActive: active),
                    "selfActive=\(selfActive) active=\(active)"
                )
            }
        }
    }
}

final class TapLifecycleTests: XCTestCase {

    func testInstructionInstallsRemovesOrKeeps() {
        XCTAssertEqual(TapLifecycle.instruction(isInstalled: false, shouldBeInstalled: false), .keep)
        XCTAssertEqual(TapLifecycle.instruction(isInstalled: false, shouldBeInstalled: true), .install)
        XCTAssertEqual(TapLifecycle.instruction(isInstalled: true, shouldBeInstalled: true), .keep)
        XCTAssertEqual(TapLifecycle.instruction(isInstalled: true, shouldBeInstalled: false), .remove)
    }

    func testADisabledTapIsReEnabledOnlyWhileStillWanted() {
        XCTAssertEqual(TapLifecycle.recovery(shouldBeInstalled: true), .reEnable)
        XCTAssertEqual(TapLifecycle.recovery(shouldBeInstalled: false), .remove)
    }

    func testBothTapsUseAKeyboardOnlyEventMask() {
        // Neither tap may ever intercept a mouse event.
        let mask = TapLifecycle.eventMask
        XCTAssertNotEqual(mask & CGEventMask(1 << CGEventType.keyDown.rawValue), 0)
        let forbiddenMouseTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved, .scrollWheel,
        ]
        for mouseType in forbiddenMouseTypes {
            XCTAssertEqual(
                mask & CGEventMask(1 << mouseType.rawValue), 0,
                "\(mouseType) must never be intercepted by either tap"
            )
        }
    }
}

// MARK: - Listen-only typing observer (pure)

final class TypingObserverPlanTests: XCTestCase {

    /// The observer reads the same snapshot as the active tap; the default is an
    /// idle Cotype with the trigger hot key registered.
    private func snapshot(
        isSelfActive: Bool = false,
        isCompletionActive: Bool = false,
        isAcceptReady: Bool = false,
        trigger: TriggerShortcut = .default,
        triggerKeyCodes: Set<UInt16> = [47],
        triggerOwnedByHotKey: Bool = true
    ) -> TapRouteSnapshot {
        TapRouteSnapshot(
            isSelfActive: isSelfActive,
            isCompletionActive: isCompletionActive,
            isAcceptReady: isAcceptReady,
            trigger: trigger,
            acceptAll: .default,
            triggerKeyCodes: triggerKeyCodes,
            triggerHandled: false,
            triggerOwnedByHotKey: triggerOwnedByHotKey
        )
    }

    private func observation(
        keyCode: UInt16,
        modifiers: KeyModifiers = KeyModifiers(),
        text: String = "",
        isRepeat: Bool = false,
        isSynthetic: Bool = false,
        _ snapshot: TapRouteSnapshot? = nil
    ) -> EditObservation? {
        (snapshot ?? self.snapshot()).typingObservation(
            keyCode: keyCode,
            modifiers: modifiers,
            text: text,
            isRepeat: isRepeat,
            isSynthetic: isSynthetic
        )
    }

    func testPrintableTypingIsReported() {
        XCTAssertEqual(observation(keyCode: 0, text: "a"), .typed("a"))
        XCTAssertEqual(observation(keyCode: 49, modifiers: KeyModifiers(shift: true), text: "A"), .typed("A"))
        XCTAssertEqual(observation(keyCode: 49, text: " "), .typed(" "))
        XCTAssertEqual(observation(keyCode: 47, text: "."), .typed("."))
    }

    func testDocumentMutationsAreReported() {
        for keyCode in [51, 117, 36, 76] as [UInt16] { // backspace, fwd delete, return, keypad enter
            XCTAssertEqual(observation(keyCode: keyCode), .mutated, "key \(keyCode)")
        }
        // Unmodified Tab with no candidate is a document mutation.
        XCTAssertEqual(observation(keyCode: 48, snapshot(isCompletionActive: true)), .mutated)
    }

    func testCaretNavigationIsReportedAsAMutation() {
        for keyCode in [115, 119, 116, 121, 123, 124, 125, 126] as [UInt16] {
            XCTAssertEqual(observation(keyCode: keyCode), .mutated, "key \(keyCode)")
        }
    }

    func testShiftTabIsNeverReported() {
        // Shift+Tab is outdent/navigation, never an edit.
        XCTAssertNil(observation(keyCode: 48, modifiers: KeyModifiers(shift: true)))
    }

    func testEscapeIsNotADocumentMutation() {
        XCTAssertNil(observation(keyCode: 53))
    }

    func testCommandChordsAreOnlyReportedWhenTheyMutateTheDocument() {
        // Paste/cut/undo are observed (never hijacked); copy is not an edit.
        XCTAssertEqual(observation(keyCode: 9, modifiers: KeyModifiers(command: true)), .mutated)
        XCTAssertEqual(observation(keyCode: 7, modifiers: KeyModifiers(command: true)), .mutated)
        XCTAssertEqual(observation(keyCode: 6, modifiers: KeyModifiers(command: true)), .mutated)
        XCTAssertNil(observation(keyCode: 8, modifiers: KeyModifiers(command: true)))
        XCTAssertNil(observation(keyCode: 0, modifiers: KeyModifiers(command: true), text: "a"))
    }

    func testControlAndOptionChordsAreNotReported() {
        XCTAssertNil(observation(keyCode: 0, modifiers: KeyModifiers(control: true), text: "a"))
        XCTAssertNil(observation(keyCode: 0, modifiers: KeyModifiers(option: true), text: "a"))
    }

    func testNonEditingKeysAreNotReported() {
        XCTAssertNil(observation(keyCode: 122)) // F1
    }

    func testCotypesOwnWindowIsNeverObserved() {
        XCTAssertNil(observation(keyCode: 0, text: "a", snapshot(isSelfActive: true)))
    }

    func testSyntheticEventsAreNeverObserved() {
        XCTAssertNil(observation(keyCode: 0, text: "a", isSynthetic: true))
        XCTAssertNil(observation(keyCode: 51, isSynthetic: true))
    }

    func testATabConsumedByTheActiveTapIsNotAlsoObserved() {
        // Unmodified Tab with a candidate ready belongs to the active tap; the
        // observer must not report it as an edit (which would cancel the accept).
        XCTAssertNil(observation(keyCode: 48, snapshot(isCompletionActive: true, isAcceptReady: true)))
    }

    func testTheAcceptAllChordConsumedByTheActiveTapIsNotAlsoObserved() {
        XCTAssertNil(observation(
            keyCode: 48,
            modifiers: KeyModifiers(option: true),
            text: "\t",
            snapshot(isCompletionActive: true, isAcceptReady: true)
        ))
    }

    func testEscapeConsumedByTheActiveTapIsNotAlsoObserved() {
        XCTAssertNil(observation(
            keyCode: 53,
            snapshot(isCompletionActive: true, isAcceptReady: true)
        ))
    }

    func testTheTriggerChordOwnedByTheHotKeyIsNotObserved() {
        // Even a shift-only trigger chord, which would otherwise look like
        // ordinary typing, is never reported while the hot key owns it.
        XCTAssertNil(observation(
            keyCode: 47,
            modifiers: KeyModifiers(shift: true),
            text: ".",
            snapshot(trigger: TriggerShortcut(modifiers: [.shift], key: "."))
        ))
        // The default Control+. trigger likewise.
        XCTAssertNil(observation(keyCode: 47, modifiers: KeyModifiers(control: true), text: "."))
    }

    func testTheTriggerChordIsObservedOnlyWhenNoPathOwnsIt() {
        // No hot key and no live interaction: the chord reaches the editor as
        // real input, so a shift-only chord is reported as typing.
        let unowned = snapshot(
            trigger: TriggerShortcut(modifiers: [.shift], key: "."),
            triggerOwnedByHotKey: false
        )
        XCTAssertEqual(
            observation(keyCode: 47, modifiers: KeyModifiers(shift: true), text: ".", unowned),
            .typed(".")
        )
        // With the tap installed as the fallback owner, it is owned again.
        XCTAssertNil(observation(
            keyCode: 47,
            modifiers: KeyModifiers(shift: true),
            text: ".",
            snapshot(
                isCompletionActive: true,
                trigger: TriggerShortcut(modifiers: [.shift], key: "."),
                triggerOwnedByHotKey: false
            )
        ))
    }

    func testAKeyTheActiveTapForwardsIsStillObserved() {
        // Tab with no candidate is forwarded by the active tap, so the observer
        // reports the document mutation.
        XCTAssertEqual(
            observation(keyCode: 48, snapshot(isCompletionActive: true, isAcceptReady: false)),
            .mutated
        )
    }
}

// MARK: - Active accept/cancel tap (pure)

final class TapRoutePlanTests: XCTestCase {

    private func snapshot(
        isSelfActive: Bool = false,
        isCompletionActive: Bool = true,
        isAcceptReady: Bool = false,
        trigger: TriggerShortcut = .default,
        acceptAll: AcceptAllShortcut = .default,
        triggerKeyCodes: Set<UInt16> = [47],
        triggerHandled: Bool = false,
        triggerOwnedByHotKey: Bool = true
    ) -> TapRouteSnapshot {
        TapRouteSnapshot(
            isSelfActive: isSelfActive,
            isCompletionActive: isCompletionActive,
            isAcceptReady: isAcceptReady,
            trigger: trigger,
            acceptAll: acceptAll,
            triggerKeyCodes: triggerKeyCodes,
            triggerHandled: triggerHandled,
            triggerOwnedByHotKey: triggerOwnedByHotKey
        )
    }

    func testUnmodifiedTabConsumesOnlyWhenACandidateIsReady() {
        XCTAssertEqual(
            snapshot(isAcceptReady: true).route(keyCode: 48, modifiers: KeyModifiers(), isRepeat: false),
            .consume(.acceptWord)
        )
        // Not ready: forwarded, and the listen-only observer reports the edit.
        XCTAssertEqual(
            snapshot(isAcceptReady: false).route(keyCode: 48, modifiers: KeyModifiers(), isRepeat: false),
            .pass
        )
    }

    func testShiftTabAlwaysPassesThrough() {
        XCTAssertEqual(
            snapshot(isAcceptReady: true).route(keyCode: 48, modifiers: KeyModifiers(shift: true), isRepeat: false),
            .pass
        )
    }

    func testOptionTabConsumesAcceptAllOnlyWhenReady() {
        XCTAssertEqual(
            snapshot(isAcceptReady: true).route(keyCode: 48, modifiers: KeyModifiers(option: true), isRepeat: false),
            .consume(.acceptAll)
        )
        XCTAssertEqual(
            snapshot(isAcceptReady: false).route(keyCode: 48, modifiers: KeyModifiers(option: true), isRepeat: false),
            .pass
        )
    }

    func testEscapeConsumesCancelOnlyWhileAnInteractionIsLive() {
        XCTAssertEqual(
            snapshot(isCompletionActive: true).route(keyCode: 53, modifiers: KeyModifiers(), isRepeat: false),
            .consume(.cancel)
        )
        XCTAssertEqual(
            snapshot(isCompletionActive: false, isAcceptReady: false)
                .route(keyCode: 53, modifiers: KeyModifiers(), isRepeat: false),
            .pass
        )
    }

    func testCommandChordsAreNeverConsumed() {
        let chord = snapshot(isAcceptReady: true)
        XCTAssertEqual(
            chord.route(keyCode: 48, modifiers: KeyModifiers(command: true), isRepeat: false), .pass
        )
        XCTAssertEqual(
            chord.route(keyCode: 47, modifiers: KeyModifiers(command: true, control: true), isRepeat: false), .pass
        )
        XCTAssertEqual(
            chord.route(keyCode: 0, modifiers: KeyModifiers(command: true), isRepeat: false), .pass
        )
    }

    func testTheTriggerChordPassesWhenTheHotKeyOwnsIt() {
        // The registered hot key fires the manual trigger; the active tap must
        // forward the chord so exactly one path handles it.
        XCTAssertEqual(
            snapshot(triggerOwnedByHotKey: true)
                .route(keyCode: 47, modifiers: KeyModifiers(control: true), isRepeat: false),
            .pass
        )
    }

    func testTheTapIsTheTriggerFallbackWhenRegistrationIsUnavailable() {
        XCTAssertEqual(
            snapshot(triggerOwnedByHotKey: false)
                .route(keyCode: 47, modifiers: KeyModifiers(control: true), isRepeat: false),
            .consume(.trigger)
        )
        XCTAssertEqual(
            snapshot(triggerHandled: true, triggerOwnedByHotKey: false)
                .route(keyCode: 47, modifiers: KeyModifiers(control: true), isRepeat: true),
            .consume(.triggerRepeat)
        )
    }

    func testTriggerRepeatIsNotConsumedByTheFallbackUnlessHandled() {
        XCTAssertEqual(
            snapshot(triggerHandled: false, triggerOwnedByHotKey: false)
                .route(keyCode: 47, modifiers: KeyModifiers(control: true), isRepeat: true),
            .pass
        )
    }

    func testUnmatchedNonEditingKeyIsForwarded() {
        XCTAssertEqual(
            snapshot().route(keyCode: 122, modifiers: KeyModifiers(), isRepeat: false), .pass
        )
    }

    func testSelfActiveNeverHandlesKeys() {
        XCTAssertEqual(
            snapshot(isSelfActive: true, isAcceptReady: true)
                .route(keyCode: 48, modifiers: KeyModifiers(), isRepeat: false),
            .pass
        )
    }

    func testSyntheticEventsFailOpen() {
        let ready = snapshot(isAcceptReady: true)
        XCTAssertEqual(
            ready.route(keyCode: 48, modifiers: KeyModifiers(), isRepeat: false, isSynthetic: true), .pass
        )
        XCTAssertEqual(
            snapshot(triggerOwnedByHotKey: false)
                .route(keyCode: 47, modifiers: KeyModifiers(control: true), isRepeat: false, isSynthetic: true),
            .pass
        )
        XCTAssertEqual(
            snapshot(isCompletionActive: true)
                .route(keyCode: 53, modifiers: KeyModifiers(), isRepeat: false, isSynthetic: true),
            .pass
        )
    }
}

// MARK: - Synthetic tagging (fail open, first)

final class SyntheticEventTagTests: XCTestCase {

    func testOnlyTheMarkerIsTagged() {
        XCTAssertNotEqual(SyntheticEventTag.marker, 0)
        XCTAssertTrue(SyntheticEventTag.isTagged(sourceUserData: SyntheticEventTag.marker))
        XCTAssertFalse(SyntheticEventTag.isTagged(sourceUserData: 0))
        XCTAssertFalse(SyntheticEventTag.isTagged(sourceUserData: SyntheticEventTag.marker &+ 1))
    }
}
