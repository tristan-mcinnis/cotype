import XCTest
@testable import CotypeCore

final class SparkleUpdaterPolicyTests: XCTestCase {

    func testNotConfiguredWhenNoFeed() {
        XCTAssertEqual(SparkleUpdaterPolicy.resolve(feedConfigured: false, storedAutoCheck: true), .notConfigured)
    }

    func testEnabledAutomaticWhenFeedConfiguredAndAutoCheckOn() {
        XCTAssertEqual(SparkleUpdaterPolicy.resolve(feedConfigured: true, storedAutoCheck: true), .enabledAutomatic)
        XCTAssertTrue(SparkleUpdaterPolicy.resolve(feedConfigured: true, storedAutoCheck: true).mayAutoCheck)
    }

    func testEnabledManualOnlyWhenFeedConfiguredButAutoCheckOff() {
        // The user turned automatic checks OFF: the updater must be available for
        // manual checks but must NOT schedule/performs a launch-time check.
        let policy = SparkleUpdaterPolicy.resolve(feedConfigured: true, storedAutoCheck: false)
        XCTAssertEqual(policy, .enabledManualOnly)
        XCTAssertFalse(policy.mayAutoCheck)
    }

    func testNotConfiguredNeverAutoChecks() {
        XCTAssertFalse(SparkleUpdaterPolicy.resolve(feedConfigured: false, storedAutoCheck: true).mayAutoCheck)
    }

    // MARK: Complete-config seam (SUFeedURL + nonempty SUPublicEDKey)

    func testConfiguredOnlyWhenBothFeedAndPublicKeyPresent() {
        XCTAssertTrue(SparkleUpdateConfig.isConfigured(feedURL: "https://u/x/appcast.xml", publicKey: "abc"))
        XCTAssertFalse(SparkleUpdateConfig.isConfigured(feedURL: "https://u/x/appcast.xml", publicKey: nil))
        XCTAssertFalse(SparkleUpdateConfig.isConfigured(feedURL: "https://u/x/appcast.xml", publicKey: ""))
        XCTAssertFalse(SparkleUpdateConfig.isConfigured(feedURL: nil, publicKey: "abc"))
        XCTAssertFalse(SparkleUpdateConfig.isConfigured(feedURL: "", publicKey: "abc"))
        XCTAssertFalse(SparkleUpdateConfig.isConfigured(feedURL: nil, publicKey: nil))
    }

    // MARK: Startup ordering (privacy race)

    func testNotConfiguredHasNoSteps() {
        XCTAssertEqual(SparkleStartup.orderedSteps(feedConfigured: false, storedAutoCheck: true), [])
    }

    func testManualOnlyAppliesPrivacyDefaultsAndFalseBeforeStarting() {
        // Privacy defaults + the auto-check OFF preference must be applied BEFORE
        // start(), and no automatic/background check step may be present. This is
        // the privacy race the reviewer flagged: the updater must never start into
        // a state that schedules a check before the user's opt-out is applied.
        let steps = SparkleStartup.orderedSteps(feedConfigured: true, storedAutoCheck: false)
        XCTAssertEqual(steps, [.applyPrivacyDefaults, .applyAutomaticCheck(false), .startUpdater])
        XCTAssertEqual(steps.first, .applyPrivacyDefaults)
        XCTAssertFalse(steps.contains(.applyAutomaticCheck(true)))
    }

    func testAutomaticAppliesPrivacyDefaultsTrueBeforeStartingAndNoDuplicateCheck() {
        // With auto-check ON, privacy defaults + apply true first, then start;
        // Sparkle's startUpdater schedules its own check, so no separate
        // background-check step is added (avoids a duplicate immediate check).
        let steps = SparkleStartup.orderedSteps(feedConfigured: true, storedAutoCheck: true)
        XCTAssertEqual(steps, [.applyPrivacyDefaults, .applyAutomaticCheck(true), .startUpdater])
        XCTAssertEqual(steps.first, .applyPrivacyDefaults)
    }
}
