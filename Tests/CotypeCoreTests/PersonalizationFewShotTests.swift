import XCTest
@testable import CotypeCore

/// The personalization ("Learn from accepted completions") few-shot summary used
/// in prompt generation must be truthful (only accepted completions are evidence)
/// and privacy-conscious (bounded per-field and total, never the raw document).
final class PersonalizationFewShotTests: XCTestCase {

    private func sample(
        prefix: String,
        completion: String,
        outcome: PersonalizationOutcome = .accepted,
        app: String = "eval"
    ) -> PersonalizationSample {
        PersonalizationSample(
            prefix: prefix,
            completion: completion,
            outcome: outcome,
            appIdentifier: app,
            timestamp: Date()
        )
    }

    private var bounded: PersonalizationFewShot.Bounds {
        PersonalizationFewShot.Bounds(maxSamples: 2, maxPrefixChars: 16, maxCompletionChars: 16, maxTotalChars: 200)
    }

    func testOnlyAcceptedSamplesAreUsed() {
        let samples = [
            sample(prefix: "let x = ", completion: "10", outcome: .accepted),
            sample(prefix: "let y = ", completion: "20", outcome: .dismissed),
            sample(prefix: "let z = ", completion: "30", outcome: .accepted),
        ]
        let text = PersonalizationFewShot.summary(for: samples, bounds: bounded)
        XCTAssertTrue(text.contains("let x = "))
        XCTAssertTrue(text.contains("let z = "))
        XCTAssertFalse(text.contains("let y = "), "dismissed completions are not training signal")
    }

    func testPerFieldCapsAreApplied() {
        let samples = [
            sample(prefix: String(repeating: "a", count: 100), completion: String(repeating: "b", count: 100)),
        ]
        let text = PersonalizationFewShot.summary(for: samples, bounds: bounded)
        // Each line's prefix and completion must be capped, and never the raw field.
        XCTAssertFalse(text.contains(String(repeating: "a", count: 100)))
        XCTAssertFalse(text.contains(String(repeating: "b", count: 100)))
    }

    func testTotalIsBounded() {
        let samples = (0..<20).map { index in
            sample(prefix: "prefix-\(index) ", completion: "completion-\(index)")
        }
        let text = PersonalizationFewShot.summary(for: samples, bounds: bounded)
        XCTAssertLessThanOrEqual(text.count, 200, "the few-shot summary must respect the total bound")
        // At most maxSamples examples are included.
        let sampleCount = text.components(separatedBy: "→").count - 1
        XCTAssertLessThanOrEqual(sampleCount, 2)
    }

    func testEmptyWhenNoAcceptedSamples() {
        let samples = [
            sample(prefix: "p", completion: "c", outcome: .dismissed),
            sample(prefix: "p", completion: "c", outcome: .failed),
        ]
        XCTAssertEqual(PersonalizationFewShot.summary(for: samples, bounds: bounded), "")
    }

    func testFiltersByAppWhenRequested() {
        let samples = [
            sample(prefix: "x ", completion: "1", app: "com.apple.dt.Xcode"),
            sample(prefix: "y ", completion: "2", app: "com.apple.TextEdit"),
        ]
        let text = PersonalizationFewShot.summary(for: samples, filterApp: "com.apple.dt.Xcode", bounds: bounded)
        XCTAssertTrue(text.contains("x "))
        XCTAssertFalse(text.contains("y "), "only the requested app's accepted samples are used")
    }
}

/// `TemplatePromptBuilder` must inject a bounded personalization summary into the
/// prompt when a provider is wired, and stay unchanged when it is not.
final class PersonalizationPromptTests: XCTestCase {

    func testInjectsSummaryWhenProviderReturnsContent() async throws {
        var builder = TemplatePromptBuilder()
        builder.personalizationSummary = { "Examples of your accepted completions:\n- let x =  → 10" }
        let prompt = try await builder.buildPrompt(context: CompletionContext(prefix: "let x = "))
        XCTAssertTrue(prompt.system.contains("Examples of your accepted completions"))
    }

    func testNoInjectionWhenProviderReturnsEmpty() async throws {
        var builder = TemplatePromptBuilder()
        builder.personalizationSummary = { "" }
        let prompt = try await builder.buildPrompt(context: CompletionContext(prefix: "let x = "))
        XCTAssertEqual(prompt.system, AutocompletePrompt.defaultSystem)
    }

    func testNoInjectionWithoutProvider() async throws {
        let builder = TemplatePromptBuilder()
        let prompt = try await builder.buildPrompt(context: CompletionContext(prefix: "let x = "))
        XCTAssertFalse(prompt.system.contains("accepted completions"))
    }
}
