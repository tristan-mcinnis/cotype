import XCTest
import CotypeCore
@testable import CotypeMacOS

/// Battery policy pauses automatic work only. The manual trigger is a direct
/// instruction and must keep working.
@MainActor
final class PowerPolicyControllerTests: XCTestCase {

    private func makeController(
        power: PowerState,
        settings: BatteryPolicy.Settings
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        defaults.set(true, forKey: CompletionController.autoSuggestKey)
        defaults.set(settings.pauseOnBattery, forKey: BatteryPolicy.pauseOnBatteryKey)
        defaults.set(settings.pauseInLowPowerMode, forKey: BatteryPolicy.pauseInLowPowerModeKey)
        let inserter = RecordingInserter()
        let controller = CompletionController(
            engineManager: EngineManager(
                modelPathOverride: "/fake/model.gguf",
                engineFactory: { _ in MockClosableEngine() }
            ),
            personalization: makePersonalizationStore(),
            overrides: AppOverridesStore(fileURL: tempFileURL("power-overrides")),
            websiteRules: makeWebsiteRulesStore(),
            powerStateProvider: FixedPowerState(power),
            inserter: inserter,
            pipelineEngineOverride: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(FocusTarget(
                appIdentifier: "com.example.editor",
                windowIdentity: 1,
                elementIdentity: 2,
                selection: .unsupported
            )),
            userDefaults: defaults
        )
        controller.debounceInterval = 0.02
        controller.cooldownInterval = 0.02
        return (controller, inserter)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 1) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testLowPowerModePausesAutomaticButNotManual() async {
        let (controller, _) = makeController(
            power: PowerState(onBattery: true, lowPowerMode: true),
            settings: BatteryPolicy.Settings(pauseOnBattery: false, pauseInLowPowerMode: true)
        )

        controller.noteTyped("x")
        let autoRan = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertFalse(autoRan, "the automatic lane must stay paused in Low Power Mode")
        XCTAssertEqual(controller.phase, .idle)

        XCTAssertTrue(controller.trigger(), "the manual trigger always runs")
        let manualRan = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(manualRan)
        XCTAssertEqual(controller.currentCandidate, "hello")
    }

    func testAutomaticLaneRunsWhenThePolicyIsOff() async {
        let (controller, _) = makeController(
            power: PowerState(onBattery: true, lowPowerMode: true),
            settings: BatteryPolicy.Settings(pauseOnBattery: false, pauseInLowPowerMode: false)
        )

        controller.noteTyped("x")
        let ran = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ran)
    }

    func testBatteryPausesOnlyWhenExplicitlyEnabled() async {
        let (paused, _) = makeController(
            power: PowerState(onBattery: true, lowPowerMode: false),
            settings: BatteryPolicy.Settings(pauseOnBattery: true, pauseInLowPowerMode: true)
        )
        paused.noteTyped("x")
        let pausedRan = await waitUntil { paused.phase == .awaitingAccept }
        XCTAssertFalse(pausedRan)

        let (running, _) = makeController(
            power: PowerState(onBattery: true, lowPowerMode: false),
            settings: BatteryPolicy.Settings(pauseOnBattery: false, pauseInLowPowerMode: true)
        )
        running.noteTyped("x")
        let runningRan = await waitUntil { running.phase == .awaitingAccept }
        XCTAssertTrue(runningRan)
    }
}
