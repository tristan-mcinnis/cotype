import XCTest
@testable import CotypeCore

final class LlamaFormattingTests: XCTestCase {
    func testGemmaPromptIncludesSystemUserAndAssistantTurn() {
        let text = LlamaCppEngine.formatGemmaPrompt(Prompt(system: "be concise", user: "hello"))
        XCTAssertEqual(
            text,
            "<|turn>system\nbe concise<turn|>\n" +
                "<|turn>user\nhello<turn|>\n" +
                "<|turn>model\n"
        )
    }

    func testGemmaPromptOmitsEmptySystemTurn() {
        let text = LlamaCppEngine.formatGemmaPrompt(Prompt(user: "hello"))
        XCTAssertFalse(text.contains("system"))
        XCTAssertTrue(text.hasPrefix("<|turn>user\n"))
        XCTAssertTrue(text.hasSuffix("<|turn>model\n"))
    }

    func testGemmaPromptIncludesSuffixAsInfillContext() {
        let text = LlamaCppEngine.formatGemmaPrompt(Prompt(
            system: "complete",
            user: "print(\"hello, ",
            suffix: "\")"
        ))
        XCTAssertTrue(text.contains("<after_cursor>\n\")\n</after_cursor>"))
        XCTAssertTrue(text.contains("</after_cursor>\n\n"))
        XCTAssertTrue(text.hasSuffix("<|turn>model\n"))
    }

    func testInvalidContextConfigurationFailsBeforeModelLoad() {
        XCTAssertThrowsError(try LlamaCppEngine(path: "/missing.gguf", nCtx: 1)) { error in
            guard let engineError = error as? LlamaCppEngine.EngineError,
                  case .invalidConfiguration = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStructuralTokensAreFiltered() {
        XCTAssertTrue(LlamaCppEngine.isStructuralToken("<|channel analysis>"))
        XCTAssertTrue(LlamaCppEngine.isStructuralToken("<|tool>"))
        XCTAssertFalse(LlamaCppEngine.isStructuralToken("<turn|>"))
        XCTAssertFalse(LlamaCppEngine.isStructuralToken("ordinary text"))
    }

    // MARK: - Context-aware truncation preserves the Gemma header structure

    func testTruncationKeepsSystemUserAndModelHeaders() {
        let prompt = Prompt(
            system: "be concise",
            user: String(repeating: "x", count: 2000),
            suffix: "\")"
        )
        let truncated = LlamaCppEngine.truncatingForContext(prompt, maxChars: 256)
        let formatted = LlamaCppEngine.formatGemmaPrompt(truncated)
        XCTAssertTrue(formatted.contains("<|turn>system\nbe concise<turn|>\n"), "system header must be preserved")
        XCTAssertTrue(formatted.contains("<|turn>user\n"), "user header must be preserved")
        XCTAssertTrue(formatted.hasSuffix("<|turn>model\n"), "model header must be preserved")
        XCTAssertTrue(formatted.contains("<after_cursor>\n\")\n</after_cursor>"), "FIM suffix block must be preserved")
    }

    func testTruncationDropsFurthestContentKeepsNearestCaret() {
        let head = String(repeating: "A", count: 200)
        let tail = String(repeating: "B", count: 12)
        let prompt = Prompt(system: "s", user: head + tail)
        let truncated = LlamaCppEngine.truncatingForContext(prompt, maxChars: 64)
        let formatted = LlamaCppEngine.formatGemmaPrompt(truncated)
        // The head (furthest from the caret) is dropped; the tail is retained.
        XCTAssertFalse(formatted.contains(String(repeating: "A", count: 200)))
        XCTAssertTrue(formatted.contains(String(repeating: "B", count: 12)), "nearest-to-caret tail must be kept")
    }

    func testTruncationLeavesShortPromptUnchanged() {
        let prompt = Prompt(system: "s", user: "print(\"hello\")")
        let truncated = LlamaCppEngine.truncatingForContext(prompt, maxChars: 4096)
        XCTAssertEqual(truncated.user, prompt.user)
        XCTAssertEqual(truncated.system, prompt.system)
    }

    func testTruncationRespectsMinimumContentBudget() {
        // Even a very small budget must leave a usable minimal user turn.
        let prompt = Prompt(user: String(repeating: "z", count: 1000))
        let truncated = LlamaCppEngine.truncatingForContext(prompt, maxChars: 40)
        XCTAssertFalse(truncated.user.isEmpty)
        XCTAssertTrue(LlamaCppEngine.formatGemmaPrompt(truncated).contains("<|turn>user\n"))
    }


    // MARK: - Total-context budget across system + prefix + suffix

    func testTruncationBoundsHugeSuffixAndKeepsNearestCaret() {
        // A ~1M-char suffix must be bounded to the total budget, keep the
        // nearest-to-caret (leading) suffix, and preserve the Gemma headers.
        let nearCaret = "LEAD-MARKER-"
        let suffix = nearCaret + String(repeating: "z", count: 1_000_000)
        let prompt = Prompt(system: "be concise", user: "func area() -> Int {\n    return ", suffix: suffix)

        let truncated = LlamaCppEngine.truncatingForContext(prompt, maxChars: 2000)
        let formatted = LlamaCppEngine.formatGemmaPrompt(truncated)

        XCTAssertLessThanOrEqual(formatted.count, 2000, "a huge suffix must not overflow the context")
        XCTAssertTrue(formatted.contains(nearCaret), "the nearest-to-caret suffix must be kept")
        XCTAssertFalse(formatted.contains(String(repeating: "z", count: 500_000)), "the far-from-caret suffix must be dropped")
        XCTAssertTrue(formatted.contains("<|turn>system\nbe concise<turn|>\n"), "system header must be preserved")
        XCTAssertTrue(formatted.contains("<|turn>user\n"))
        XCTAssertTrue(formatted.hasSuffix("<|turn>model\n"))
        XCTAssertTrue(formatted.contains("<after_cursor>"))
        XCTAssertTrue(formatted.contains("</after_cursor>"))
    }

    func testTruncationKeepsNearestPrefixWithLargeSuffix() {
        let prompt = Prompt(user: String(repeating: "x", count: 100_000), suffix: String(repeating: "y", count: 1000))
        let truncated = LlamaCppEngine.truncatingForContext(prompt, maxChars: 4000)
        let formatted = LlamaCppEngine.formatGemmaPrompt(truncated)
        XCTAssertLessThanOrEqual(formatted.count, 4000)
        XCTAssertTrue(formatted.contains("<|turn>model\n"))
    }
}
