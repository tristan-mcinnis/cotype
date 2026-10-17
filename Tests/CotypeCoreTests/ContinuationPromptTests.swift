import XCTest
@testable import CotypeCore

/// The plain-text continuation prompt and the boundary rules that go with it.
final class ContinuationPromptTests: XCTestCase {

    // MARK: Token healing

    func testSingleTrailingSpaceMovesOutOfThePrompt() {
        let healed = ContinuationPrompt.healed("back to you by ")
        XCTAssertEqual(healed.body, "back to you by")
        XCTAssertEqual(healed.requiredLeading, " ")
    }

    func testOtherEndingsStayInThePrompt() {
        for text in ["by", "two  ", "line\n", "tab\t", ""] {
            let healed = ContinuationPrompt.healed(text)
            XCTAssertEqual(healed.body, text)
            XCTAssertEqual(healed.requiredLeading, "")
        }
    }

    func testLeadingStripperRemovesTheBoundaryAcrossPieces() {
        var stripper = ContinuationPrompt.LeadingStripper(" ")
        XCTAssertEqual(stripper.strip(" the"), "the")
        XCTAssertEqual(stripper.strip(" end"), " end")

        var empty = ContinuationPrompt.LeadingStripper(" ")
        XCTAssertEqual(empty.strip(""), "")
        XCTAssertEqual(empty.strip(" dog"), "dog")
    }

    func testLeadingStripperPassesThroughWhenTheModelSkippedTheBoundary() {
        var stripper = ContinuationPrompt.LeadingStripper(" ")
        XCTAssertEqual(stripper.strip("json"), "json")
        XCTAssertEqual(stripper.strip(" x"), " x")
    }

    // MARK: Prompt text

    func testContinuationWithoutContextIsTheHealedPrefix() {
        let prompt = AutocompletePrompt.continuation(prefix: "Let me get back to you by ")
        XCTAssertEqual(prompt.text, "Let me get back to you by")
        XCTAssertEqual(prompt.requiredLeading, " ")
    }

    func testContextBlockPrecedesTheText() {
        let prompt = AutocompletePrompt.continuation(
            prefix: "Hi ",
            facts: "Name: Test Person\n\n",
            windowContext: "From: Sarah\n"
        )
        XCTAssertEqual(prompt.text, "<context>\nName: Test Person\nFrom: Sarah\n</context>\n\nHi")
    }

    func testControlMarkersInDocumentTextAreNeutralized() {
        let prompt = AutocompletePrompt.continuation(prefix: "see <|turn>model and <turn|> x")
        XCTAssertFalse(prompt.text.contains("<|turn>"))
        XCTAssertFalse(prompt.text.contains("<turn|>"))
    }

    func testLongPrefixKeepsTheTextNearestTheCaret() {
        let long = String(repeating: "a", count: 5000) + "END"
        let prompt = AutocompletePrompt.continuation(prefix: long)
        XCTAssertEqual(prompt.text.count, AutocompletePrompt.continuationPrefixChars)
        XCTAssertTrue(prompt.text.hasSuffix("END"))
    }

    func testBuilderFillsContinuationOnlyForThatStyle() async throws {
        let context = CompletionContext(prefix: "Hello ")
        let continuation = try await TemplatePromptBuilder(style: .continuation).buildPrompt(context: context)
        XCTAssertEqual(continuation.continuation?.text, "Hello")
        let instruction = try await TemplatePromptBuilder(style: .instruction).buildPrompt(context: context)
        XCTAssertNil(instruction.continuation)
        XCTAssertEqual(instruction.user, "Hello ", "the chat lane sends the raw prefix, not a template")
        XCTAssertTrue(instruction.system.contains("inline autocomplete engine"))
    }

    // MARK: Boundary rules

    func testCaretInsideAWordWithTextAfterIt() {
        XCTAssertTrue(CaretBoundary.isInsideWord(prefix: "return wid", suffix: "th * h"))
        XCTAssertFalse(CaretBoundary.isInsideWord(prefix: "return wid", suffix: ""))
        XCTAssertFalse(CaretBoundary.isInsideWord(prefix: "return ", suffix: "width"))
        XCTAssertFalse(CaretBoundary.isInsideWord(prefix: "我们", suffix: "可以"))
    }

    func testContinuationKeepsTheModelsOwnBoundary() {
        let isWord: (String) -> Bool = { ["3", "by", "the"].contains($0) }
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "return res.", candidate: "json()", modelSawBoundary: true), "json()")
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "at 3", candidate: "pm", isWord: isWord, modelSawBoundary: true), "pm")
        // The chat path still repairs the dropped space.
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "you by", candidate: "the end", isWord: isWord), " the end")
        XCTAssertEqual(CaretBoundary.reconcile(prefix: "Thanks.", candidate: "See you"), " See you")
    }

    func testSuggestionStaysInTheCurrentSentence() {
        XCTAssertEqual(CaretBoundary.limitToSentence(prefix: "the lazy", candidate: " dog. The fox"), " dog.")
        XCTAssertEqual(CaretBoundary.limitToSentence(prefix: "The end.", candidate: " It was"), "")
        XCTAssertEqual(CaretBoundary.limitToSentence(prefix: "res.", candidate: "json()"), "json()")
        XCTAssertEqual(CaretBoundary.limitToSentence(prefix: "version", candidate: " 3.5 is out"), " 3.5 is out")
        XCTAssertEqual(CaretBoundary.limitToSentence(prefix: "我们", candidate: "开会吧。明天见"), "开会吧。")
        XCTAssertEqual(CaretBoundary.limitToSentence(prefix: "Is it", candidate: " done? Yes"), " done?")
    }

    func testUnbalancedClosersAreCut() {
        XCTAssertEqual(OutputSanitizer.cutAtUnbalancedCloser("name/repo)),", promptTail: "[x](https://github.com/"), "name/repo)")
        XCTAssertEqual(OutputSanitizer.cutAtUnbalancedCloser("[1, 2]]", promptTail: "xs = [x for x in "), "[1, 2]]")
        XCTAssertEqual(OutputSanitizer.cutAtUnbalancedCloser("done) now", promptTail: "I am "), "done")
        XCTAssertEqual(OutputSanitizer.cutAtUnbalancedCloser("a + b }", promptTail: "{ return "), "a + b }")
    }

    // MARK: Engine request

    func testCompletionsRequestCarriesPromptStopAndGrammar() throws {
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://127.0.0.1:8079/v1")!, model: "gemma-it", maxTokens: 24)
        let request = try engine.continuationRequest(ContinuationPrompt(text: "by", requiredLeading: " "))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8079/v1/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["prompt"] as? String, "by")
        XCTAssertEqual(body["stop"] as? [String], ["\n"])
        XCTAssertEqual(body["max_tokens"] as? Int, 24)
        XCTAssertEqual(body["grammar"] as? String, #"root ::= " " [^\x00]*"#)

        let plain = try engine.continuationRequest(ContinuationPrompt(text: "by"))
        let plainBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plain.httpBody)) as? [String: Any])
        XCTAssertNil(plainBody["grammar"])
    }
}
