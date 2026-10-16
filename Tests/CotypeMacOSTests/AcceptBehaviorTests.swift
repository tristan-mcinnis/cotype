import XCTest
@testable import CotypeMacOS
import CotypeCore

final class AcceptBehaviorTests: XCTestCase {
    private func router(_ accept: AcceptBehavior) -> GlobalKeyRouter {
        GlobalKeyRouter(accept: accept) { _ in nil }
    }

    private func route(_ r: GlobalKeyRouter, _ keyCode: UInt16, ready: Bool = true) -> ShortcutIntent {
        r.route(keyCode: keyCode, modifiers: KeyModifiers(), isSelfActive: false,
                isCompletionActive: ready, isAcceptReady: ready, isRepeat: false)
    }

    func testDefaultTabAcceptsNextWord() {
        XCTAssertEqual(route(router(.default), 48), .acceptWord)
    }

    func testWholeSuggestionModeAcceptsAll() {
        XCTAssertEqual(route(router(AcceptBehavior(key: .tab, mode: .wholeSuggestion)), 48), .acceptAll)
    }

    func testRightArrowFreesTab() {
        let r = router(AcceptBehavior(key: .rightArrow, mode: .nextWord))
        XCTAssertEqual(route(r, 124), .acceptWord)
        XCTAssertEqual(route(r, 48), .passthrough)
    }

    func testAcceptKeyPassesThroughWithoutSuggestion() {
        XCTAssertEqual(route(router(.default), 48, ready: false), .passthrough)
    }

    func testQuickLaunchExcludedByDefault() {
        XCTAssertFalse(AppCompatibility.isEnabled(bundleID: "com.tristanmcinnis.quick-launch", override: nil))
    }

    func testBehaviorRoundTrips() {
        let defaults = UserDefaults(suiteName: "AcceptBehaviorTests")!
        defaults.removePersistentDomain(forName: "AcceptBehaviorTests")
        XCTAssertEqual(AcceptBehaviorStore.load(userDefaults: defaults), .default)
        let custom = AcceptBehavior(key: .rightArrow, mode: .wholeSuggestion)
        AcceptBehaviorStore.save(custom, userDefaults: defaults)
        XCTAssertEqual(AcceptBehaviorStore.load(userDefaults: defaults), custom)
    }
}
