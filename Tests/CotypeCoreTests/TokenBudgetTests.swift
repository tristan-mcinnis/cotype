import XCTest
@testable import CotypeCore

/// One policy decides the token budget everywhere. These tests pin the table the
/// Settings pane displays and both engines transmit.
final class TokenBudgetTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "token-budget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAutoFollowsSuggestionLengthForEveryLength() {
        for length in SuggestionLength.allCases {
            let defaults = makeDefaults()
            defaults.set(length.rawValue, forKey: SuggestionLength.defaultsKey)
            let budget = TokenBudget.effective(defaults)
            XCTAssertEqual(budget.tokens, length.maxTokens)
            XCTAssertEqual(budget.source, .automatic(length))
            XCTAssertTrue(budget.summary.contains("\(length.maxTokens) tokens"))
        }
    }

    func testAutoIsTheDefaultAndIgnoresAStoredLegacyOverride() {
        let defaults = makeDefaults()
        defaults.set(512, forKey: TokenBudget.explicitValueKey)
        XCTAssertEqual(TokenBudget.mode(defaults), .auto)
        XCTAssertEqual(TokenBudget.effective(defaults).tokens, SuggestionLength.default.maxTokens)
    }

    func testExplicitOverrideAppliesAndIsClamped() {
        let defaults = makeDefaults()
        defaults.set(TokenBudget.Mode.explicit.rawValue, forKey: TokenBudget.modeKey)

        defaults.set(64, forKey: TokenBudget.explicitValueKey)
        XCTAssertEqual(TokenBudget.effective(defaults).tokens, 64)
        XCTAssertEqual(TokenBudget.effective(defaults).source, .explicitOverride)

        defaults.set(100_000, forKey: TokenBudget.explicitValueKey)
        XCTAssertEqual(TokenBudget.effective(defaults).tokens, TokenBudget.maximum)

        defaults.set(0, forKey: TokenBudget.explicitValueKey)
        XCTAssertEqual(TokenBudget.effective(defaults).tokens, TokenBudget.minimum)
    }

    func testExplicitModeWithoutAStoredValueUsesTheDocumentedDefault() {
        let defaults = makeDefaults()
        defaults.set(TokenBudget.Mode.explicit.rawValue, forKey: TokenBudget.modeKey)
        XCTAssertEqual(TokenBudget.effective(defaults).tokens, TokenBudget.explicitDefault)
    }

    func testUnknownModeFallsBackToAutoInsteadOfSilentlyTrustingAValue() {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: TokenBudget.modeKey)
        defaults.set(999, forKey: TokenBudget.explicitValueKey)
        XCTAssertEqual(TokenBudget.mode(defaults), .auto)
        XCTAssertEqual(TokenBudget.effective(defaults).tokens, SuggestionLength.default.maxTokens)
    }

    /// The displayed number is the transmitted number: `daemonEngine` builds its
    /// engine from this exact policy, and the engine clamps to the same ceiling.
    func testDisplayedBudgetEqualsTheEngineBudget() {
        let defaults = makeDefaults()
        defaults.set(TokenBudget.Mode.explicit.rawValue, forKey: TokenBudget.modeKey)
        defaults.set(1024, forKey: TokenBudget.explicitValueKey)
        let displayed = TokenBudget.effective(defaults).tokens
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "http://127.0.0.1:1/v1")!,
            model: "m",
            maxTokens: displayed
        )
        XCTAssertEqual(engine.maxTokens, displayed)
        XCTAssertEqual(displayed, TokenBudget.maximum)
    }
}
