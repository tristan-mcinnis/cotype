import XCTest
@testable import CotypeCore

final class PowerPolicyTests: XCTestCase {

    func testLowPowerModePausesAutoByDefault() {
        let settings = BatteryPolicy.Settings(pauseOnBattery: false, pauseInLowPowerMode: true)
        XCTAssertTrue(BatteryPolicy.pausesAutomatic(
            PowerState(onBattery: false, lowPowerMode: true),
            settings: settings
        ))
    }

    func testBatteryDoesNotPauseUnlessTheUserOptedIn() {
        let settings = BatteryPolicy.Settings(pauseOnBattery: false, pauseInLowPowerMode: true)
        XCTAssertFalse(BatteryPolicy.pausesAutomatic(
            PowerState(onBattery: true, lowPowerMode: false),
            settings: settings
        ))
    }

    func testExplicitBatteryOptInPauses() {
        let settings = BatteryPolicy.Settings(pauseOnBattery: true, pauseInLowPowerMode: false)
        XCTAssertTrue(BatteryPolicy.pausesAutomatic(
            PowerState(onBattery: true, lowPowerMode: false),
            settings: settings
        ))
        XCTAssertFalse(BatteryPolicy.pausesAutomatic(.externalPower, settings: settings))
    }

    func testLowPowerOptOutStillHonorsBatteryOptIn() {
        let settings = BatteryPolicy.Settings(pauseOnBattery: true, pauseInLowPowerMode: false)
        XCTAssertTrue(BatteryPolicy.pausesAutomatic(
            PowerState(onBattery: true, lowPowerMode: true),
            settings: settings
        ))
    }

    func testDefaultsRespectLowPowerModeButNotBattery() {
        let defaults = makeUserDefaults()
        let settings = BatteryPolicy.Settings.current(defaults)
        XCTAssertFalse(settings.pauseOnBattery)
        XCTAssertTrue(settings.pauseInLowPowerMode)
    }
}
