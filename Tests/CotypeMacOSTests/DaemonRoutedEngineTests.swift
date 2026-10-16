import XCTest
@testable import CotypeMacOS
import CotypeCore

final class DaemonRoutedEngineTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "daemon-routed-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDaemonEngineNilWhenDisabled() {
        XCTAssertNil(DaemonRoutedEngine.daemonEngine(defaults: makeDefaults()))
        XCTAssertFalse(DaemonRoutedEngine.isDaemonMode(defaults: makeDefaults()))
    }

    func testDaemonEngineBuiltWhenEnabledWithDefaults() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine?.modelAlias, DaemonRoutedEngine.defaultModel)
    }

    func testCustomModelAliasIsHonoredButHiddenEndpointOverrideIsIgnored() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)
        defaults.set("https://remote.example/v1", forKey: DaemonRoutedEngine.endpointKey)
        defaults.set("other-model", forKey: DaemonRoutedEngine.modelKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine?.modelAlias, "other-model")
        XCTAssertEqual(engine?.statusClient.baseURL, LocalModelsStatusClient.defaultControlPlaneURL)
    }

    func testStreamUsesFallbackWhenDisabled() async throws {
        let engine = DaemonRoutedEngine(
            fallback: MockInferenceEngine(response: "fallback path", wordDelayNanoseconds: 0),
            defaults: makeDefaults()
        )
        var text = ""
        for try await event in engine.stream(prompt: Prompt(user: "hello")) {
            if case .token(let token) = event { text += token }
        }
        XCTAssertEqual(text, "fallback path")
    }

    /// The daemon lane honors the same generation tuning as the standalone pane,
    /// so a completion stays short and deterministic by default.
    func testDaemonEngineThreadsGenerationSettingsFromDefaults() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)
        defaults.set(48, forKey: DaemonRoutedEngine.maxTokensKey)
        defaults.set(0.25, forKey: DaemonRoutedEngine.temperatureKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine?.maxTokens, 48)
        XCTAssertEqual(engine?.temperature, 0.25)
    }

    func testDaemonEngineDefaultsToShortDeterministicGeneration() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine?.maxTokens, SuggestionLength.default.maxTokens)
        XCTAssertEqual(engine?.temperature, 0)
    }

    func testDaemonEngineClampsOutOfRangeGenerationSettings() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)
        defaults.set(100_000, forKey: DaemonRoutedEngine.maxTokensKey)
        defaults.set(9.0, forKey: DaemonRoutedEngine.temperatureKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine?.maxTokens, OpenAICompatibleEngine.maxAllowedTokens)
        XCTAssertEqual(engine?.temperature, OpenAICompatibleEngine.maxTemperature)
    }
}
