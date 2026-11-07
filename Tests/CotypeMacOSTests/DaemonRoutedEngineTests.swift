import XCTest
@testable import CotypeMacOS
import CotypeCore

final class DaemonRoutedEngineTests: XCTestCase {

    func testDaemonEngineUsesDefaultModel() {
        let defaults = makeUserDefaults()
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine.modelAlias, DaemonRoutedEngine.defaultModel)
    }

    func testCustomModelAliasIsHonoredButHiddenEndpointOverrideIsIgnored() {
        let defaults = makeUserDefaults()
        defaults.set("https://remote.example/v1", forKey: DaemonRoutedEngine.endpointKey)
        defaults.set("other-model", forKey: DaemonRoutedEngine.modelKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine.modelAlias, "other-model")
        XCTAssertEqual(engine.statusClient.baseURL, LocalModelsStatusClient.defaultControlPlaneURL)
    }

    /// The daemon lane honors the generation tuning in Settings,
    /// so a completion stays short and deterministic by default.
    func testDaemonEngineThreadsGenerationSettingsFromDefaults() {
        let defaults = makeUserDefaults()
        defaults.set(TokenBudget.Mode.explicit.rawValue, forKey: TokenBudget.modeKey)
        defaults.set(48, forKey: DaemonRoutedEngine.maxTokensKey)
        defaults.set(0.25, forKey: DaemonRoutedEngine.temperatureKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine.maxTokens, 48)
        XCTAssertEqual(engine.temperature, 0.25)
    }

    func testDaemonEngineDefaultsToShortDeterministicGeneration() {
        let defaults = makeUserDefaults()
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine.maxTokens, SuggestionLength.default.maxTokens)
        XCTAssertEqual(engine.temperature, 0)
    }

    func testDaemonEngineClampsOutOfRangeGenerationSettings() {
        let defaults = makeUserDefaults()
        defaults.set(TokenBudget.Mode.explicit.rawValue, forKey: TokenBudget.modeKey)
        defaults.set(100_000, forKey: DaemonRoutedEngine.maxTokensKey)
        defaults.set(9.0, forKey: DaemonRoutedEngine.temperatureKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine.maxTokens, OpenAICompatibleEngine.maxAllowedTokens)
        XCTAssertEqual(engine.temperature, OpenAICompatibleEngine.maxTemperature)
    }

    /// A stored budget left behind by an older build is not trusted in Auto
    /// mode: the suggestion length is the effective policy.
    func testStoredBudgetIsIgnoredInAutoMode() {
        let defaults = makeUserDefaults()
        defaults.set(64, forKey: DaemonRoutedEngine.maxTokensKey)
        defaults.set(SuggestionLength.short.rawValue, forKey: SuggestionLength.defaultsKey)
        let engine = DaemonRoutedEngine.daemonEngine(defaults: defaults)
        XCTAssertEqual(engine.maxTokens, SuggestionLength.short.maxTokens)
    }
}
