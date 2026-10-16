import XCTest
import ApplicationServices
@testable import CotypeMacOS

final class FocusedEditorResolverTests: XCTestCase {
    private func facts(
        role: String,
        focused: Bool = false,
        enabled: Bool = true,
        string: Bool = true,
        selection: Bool = true,
        settable: Bool = true,
        frame: Bool = true,
        depth: Int = 0
    ) -> AXEditorCandidateFacts {
        AXEditorCandidateFacts(
            role: role,
            isFocused: focused,
            isEnabled: enabled,
            hasStringValue: string,
            hasSelection: selection,
            selectedTextSettable: settable,
            hasUsableFrame: frame,
            depth: depth
        )
    }

    func testElectronFocusedGroupLosesToRealTextAreaDescendant() {
        let group = facts(role: kAXGroupRole, focused: true, string: true, selection: true, settable: false)
        let textArea = facts(role: kAXTextAreaRole, focused: false, string: true, selection: true, settable: true)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [group, textArea]), 1)
    }

    func testFocusedNativeTextAreaWins() {
        let textArea = facts(role: kAXTextAreaRole, focused: true)
        let generic = facts(role: kAXGroupRole, focused: false, settable: false)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [textArea, generic]), 0)
    }

    func testFocusedEditableBreaksTie() {
        let inactive = facts(role: kAXTextFieldRole)
        let focused = facts(role: kAXTextFieldRole, focused: true)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [inactive, focused]), 1)
    }

    func testAmbiguousEqualEditorsFailClosed() {
        let a = facts(role: kAXTextAreaRole)
        let b = facts(role: kAXTextAreaRole)
        XCTAssertNil(AXEditorResolutionPolicy.chosenIndex(from: [a, b]))
    }

    func testDisabledOrFramelessCandidatesAreRejected() {
        XCTAssertNil(AXEditorResolutionPolicy.chosenIndex(from: [
            facts(role: kAXTextAreaRole, enabled: false),
            facts(role: kAXTextAreaRole, frame: false),
        ]))
    }

    // MARK: - Depth-aware tie-breaking

    func testShallowestTopScoreWinsAnEqualScoreTie() {
        let shallow = facts(role: kAXTextAreaRole, depth: 0)
        let deep = facts(role: kAXTextAreaRole, depth: 3)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [shallow, deep]), 0)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [deep, shallow]), 1)
    }

    func testDepthNeverOutranksABetterScore() {
        // The deeper candidate is focused and settable; depth only breaks ties,
        // so the stronger score still wins.
        let shallowUnfocused = facts(role: kAXTextAreaRole, depth: 0)
        let deepFocused = facts(role: kAXTextAreaRole, focused: true, depth: 4)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [shallowUnfocused, deepFocused]), 1)
    }

    func testSameDepthTiesStillFailClosed() {
        XCTAssertNil(AXEditorResolutionPolicy.chosenIndex(from: [
            facts(role: kAXTextAreaRole, depth: 2),
            facts(role: kAXTextAreaRole, depth: 2),
        ]))
        // Two equally shallow winners plus a deeper one is still ambiguous.
        XCTAssertNil(AXEditorResolutionPolicy.chosenIndex(from: [
            facts(role: kAXTextAreaRole, depth: 1),
            facts(role: kAXTextAreaRole, depth: 1),
            facts(role: kAXTextAreaRole, depth: 5),
        ]))
    }

    func testUniqueShallowestWinsAmongThreeEqualScores() {
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [
            facts(role: kAXTextAreaRole, depth: 6),
            facts(role: kAXTextAreaRole, depth: 2),
            facts(role: kAXTextAreaRole, depth: 9),
        ]), 1)
    }

    func testReportedContainerLosesToTextAreaAndDepthBreaksTheRest() {
        let group = facts(role: kAXGroupRole, focused: true, string: true, selection: true, settable: false, depth: 0)
        let textArea = facts(role: kAXTextAreaRole, string: true, selection: true, settable: true, depth: 2)
        let copy = facts(role: kAXTextAreaRole, string: true, selection: true, settable: true, depth: 7)
        XCTAssertEqual(AXEditorResolutionPolicy.chosenIndex(from: [group, textArea, copy]), 1)
    }

    // MARK: - AXValue read gating

    func testTextRolesAlwaysHaveTheirValueRead() {
        XCTAssertTrue(AXEditorReadPolicy.shouldReadTextValue(
            role: kAXTextAreaRole, isFocused: false, hasSelection: false, selectedTextSettable: false
        ))
        XCTAssertTrue(AXEditorReadPolicy.shouldReadTextValue(
            role: kAXTextFieldRole, isFocused: false, hasSelection: false, selectedTextSettable: false
        ))
    }

    func testIrrelevantNonTextNodesNeverHaveTheirValueRead() {
        for role in [kAXGroupRole, kAXStaticTextRole, kAXButtonRole, kAXWindowRole, ""] {
            XCTAssertFalse(
                AXEditorReadPolicy.shouldReadTextValue(
                    role: role, isFocused: false, hasSelection: false, selectedTextSettable: false
                ),
                "\(role) is not a plausible editor; its AXValue must not be read"
            )
        }
    }

    func testPlausibleNonTextNodesStillHaveTheirValueRead() {
        XCTAssertTrue(AXEditorReadPolicy.shouldReadTextValue(
            role: kAXGroupRole, isFocused: true, hasSelection: false, selectedTextSettable: false
        ))
        XCTAssertTrue(AXEditorReadPolicy.shouldReadTextValue(
            role: kAXGroupRole, isFocused: false, hasSelection: true, selectedTextSettable: false
        ))
        XCTAssertTrue(AXEditorReadPolicy.shouldReadTextValue(
            role: kAXGroupRole, isFocused: false, hasSelection: false, selectedTextSettable: true
        ))
    }

    // MARK: - String-value probe without copying the document

    func testTextRoleWithACharacterCountIsKnownToHoldAString() {
        XCTAssertEqual(AXEditorReadPolicy.knownStringValue(role: kAXTextAreaRole, characterCount: 120_000), true)
        XCTAssertEqual(AXEditorReadPolicy.knownStringValue(role: kAXTextFieldRole, characterCount: 0), true)
    }

    func testAnythingElseFallsBackToReadingTheValue() {
        // No count: the value must still be read.
        XCTAssertNil(AXEditorReadPolicy.knownStringValue(role: kAXTextAreaRole, characterCount: nil))
        XCTAssertNil(AXEditorReadPolicy.knownStringValue(role: kAXTextAreaRole, characterCount: -1))
        // A focused Chromium group or other non-text role keeps the old read.
        XCTAssertNil(AXEditorReadPolicy.knownStringValue(role: kAXGroupRole, characterCount: 40))
        XCTAssertNil(AXEditorReadPolicy.knownStringValue(role: "AXWebArea", characterCount: 40))
    }

    // MARK: - Focus seed fallback policy

    func testFirstResolvedPrefersTheEarlierSeed() {
        let resolved = AXFocusSeedPolicy.firstResolved([{ Optional(1) }, { Optional(2) }])
        XCTAssertEqual(resolved, 1)
    }

    func testFirstResolvedFallsBackLazilyWhenAnEarlierSeedYieldsNothing() {
        var secondProviderCalled = false
        var thirdProviderCalled = false
        let resolved: Int? = AXFocusSeedPolicy.firstResolved([
            { nil },
            { secondProviderCalled = true; return 2 },
            { thirdProviderCalled = true; return 3 },
        ])
        XCTAssertEqual(resolved, 2)
        XCTAssertTrue(secondProviderCalled)
        XCTAssertFalse(thirdProviderCalled, "providers after the first success must not run (lazy system-wide read)")
    }

    func testFirstResolvedReturnsNilWhenNoSeedResolves() {
        XCTAssertNil(AXFocusSeedPolicy.firstResolved([{ nil }, { nil }]))
        XCTAssertNil(AXFocusSeedPolicy.firstResolved([{ nil }]))
    }

    func testFirstResolvedWithNoProvidersResolvesNothing() {
        XCTAssertNil(AXFocusSeedPolicy.firstResolved([] as [() -> Int?]))
    }

    func testSystemWideSeedIsRejectedUnlessItBelongsToTheFrontmostProcess() {
        XCTAssertTrue(AXFocusSeedPolicy.acceptsSystemWideSeed(seedPID: 42, frontmostPID: 42))
        XCTAssertFalse(AXFocusSeedPolicy.acceptsSystemWideSeed(seedPID: 7, frontmostPID: 42))
        XCTAssertFalse(AXFocusSeedPolicy.acceptsSystemWideSeed(seedPID: nil, frontmostPID: 42))
    }
}
