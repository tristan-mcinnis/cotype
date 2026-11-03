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

    func testTrailingWordMovesOutWithTheSpaceBeforeIt() {
        let healed = ContinuationPrompt.healed("so i thin")
        XCTAssertEqual(healed.body, "so i")
        XCTAssertEqual(healed.requiredLeading, " thin")
    }

    func testTrailingWordAfterALineBreakOrPunctuationLeavesThemInThePrompt() {
        let line = ContinuationPrompt.healed("done.\n\nlet me kno")
        XCTAssertEqual(line.body, "done.\n\nlet me")
        XCTAssertEqual(line.requiredLeading, " kno")
        let start = ContinuationPrompt.healed("done.\n\nlet")
        XCTAssertEqual(start.body, "done.\n\n")
        XCTAssertEqual(start.requiredLeading, "let")
        let member = ContinuationPrompt.healed("res.js")
        XCTAssertEqual(member.body, "res.")
        XCTAssertEqual(member.requiredLeading, "js")
    }

    func testHealingOnlySpacePutsAWordBack() {
        let word = ContinuationPrompt(text: "so i", requiredLeading: " thin").healingOnlySpace
        XCTAssertEqual(word.text, "so i thin")
        XCTAssertEqual(word.requiredLeading, "")
        let space = ContinuationPrompt(text: "so i", requiredLeading: " ").healingOnlySpace
        XCTAssertEqual(space.requiredLeading, " ")
    }

    func testLeadingStripperRemovesAWordFromInsideOneToken() {
        var stripper = ContinuationPrompt.LeadingStripper(" thin")
        XCTAssertEqual(stripper.strip(" think"), "k")
        XCTAssertEqual(stripper.strip(" we"), " we")
    }

    func testLeadingStripperKeepsWhatMatchedWhenTheModelLeavesTheWord() {
        var stripper = ContinuationPrompt.LeadingStripper(" by")
        XCTAssertEqual(stripper.strip(" the"), " the")
        XCTAssertEqual(stripper.strip(" end"), " end")
    }

    func testAFinishedWordStaysInThePrompt() {
        for text in ["lets not go to", "I went to The", "and that's why I"] {
            let healed = ContinuationPrompt.healed(text)
            XCTAssertEqual(healed.body, text)
            XCTAssertEqual(healed.requiredLeading, "")
        }
    }

    func testOtherEndingsStayInThePrompt() {
        for text in ["by", "two  ", "line\n", "tab\t", "", "我觉得", String(repeating: "a", count: 30) + " " + String(repeating: "b", count: 25)] {
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

    func testProseBeginsTheModelTurnWithTheHealedPrefix() {
        let prompt = AutocompletePrompt.continuation(prefix: "Let me get back to you by ")
        XCTAssertEqual(
            prompt.text,
            "<|turn>user\n\(AutocompletePrompt.continuationTask)<turn|>\n<|turn>model\nLet me get back to you by"
        )
        XCTAssertEqual(prompt.requiredLeading, " ")
    }

    func testCodeIsSentAsTheBareDocument() {
        let code = "func add(a: Int, b: Int) -> Int {\n    return "
        let prompt = AutocompletePrompt.continuation(prefix: code, facts: "Name: Test Person")
        XCTAssertEqual(prompt.text + prompt.requiredLeading, code)
    }

    func testVisibleTextFramesAReply() {
        let prompt = AutocompletePrompt.continuation(prefix: "Sure, ", windowContext: "Sarah: lunch at noon?\n")
        XCTAssertTrue(prompt.text.contains("\(AutocompletePrompt.continuationReplyTask)\nSarah: lunch at noon?<turn|>"))
        XCTAssertTrue(prompt.text.hasSuffix("<|turn>model\nSure,"))
    }

    func testFactsStayOutOfTextThatDoesNotCallForThem() {
        for prefix in ["I think we should ", "The meeting went", "我觉得", "Can you send me the"] {
            let prompt = AutocompletePrompt.continuation(prefix: prefix, facts: "Name: Test Person")
            XCTAssertFalse(prompt.text.contains("Test Person"), prefix)
        }
    }

    func testFactsReachTextThatCallsForThem() {
        for prefix in ["My email is ", "You can reach me at ", "Best regards,\n", "I'm based in ", "我叫"] {
            let prompt = AutocompletePrompt.continuation(prefix: prefix, facts: "Name: Test Person\n\n")
            XCTAssertTrue(prompt.text.contains("\(AutocompletePrompt.continuationFactsHeading)\nName: Test Person<turn|>"), prefix)
        }
    }

    func testTooLittleTextIsNotWorthAGeneration() {
        for prefix in ["", "  ", "hey", "I'm", "So ", "你"] {
            XCTAssertFalse(TextKind.hasEnoughToContinue(prefix), prefix)
        }
        for prefix in ["thanks", "I think", "我觉得"] {
            XCTAssertTrue(TextKind.hasEnoughToContinue(prefix), prefix)
        }
    }

    func testPipelineNamesWhyItAbstained() async throws {
        func abstention(prefix: String, suffix: String) async throws -> NotShownReason? {
            let pipeline = CompletionPipeline(
                contextProvider: StaticContextProvider(),
                promptBuilder: TemplatePromptBuilder(),
                engine: MockInferenceEngine(response: "words", wordDelayNanoseconds: 0),
                renderer: NoopRenderer(),
                inserter: PrintInserter()
            )
            pipeline.abstainsOnTooLittleText = true
            let request = CompletionRequest(appIdentifier: "test", prefix: prefix, suffix: suffix, extra: [:])
            _ = try await pipeline.completeWithOutcome(request)
            return pipeline.lastAbstention
        }
        let tooShort = try await abstention(prefix: "hey", suffix: "")
        XCTAssertEqual(tooShort, .abstainedTooLittleText)
        let insideWord = try await abstention(prefix: "hel", suffix: "lo there")
        XCTAssertEqual(insideWord, .abstainedInsideWord)
        let generated = try await abstention(prefix: "Thanks for sending the ", suffix: "")
        XCTAssertNil(generated)
    }

    func testPipelineAbstainsOnTooLittleTextOnlyWithoutVisibleText() async throws {
        func outcome(_ prefix: String, window: String = "") async throws -> CompletionOutcome {
            let pipeline = CompletionPipeline(
                contextProvider: StaticContextProvider(),
                promptBuilder: TemplatePromptBuilder(),
                engine: MockInferenceEngine(response: "words", wordDelayNanoseconds: 0),
                renderer: NoopRenderer(),
                inserter: PrintInserter()
            )
            pipeline.abstainsOnTooLittleText = true
            let request = CompletionRequest(
                appIdentifier: "test",
                prefix: prefix,
                suffix: "",
                extra: window.isEmpty ? [:] : ["windowContext": window]
            )
            return try await pipeline.completeWithOutcome(request).outcome
        }
        let tooShort = try await outcome("hey")
        XCTAssertEqual(tooShort, .noSuggestion)
        let framed = try await outcome("Hi ", window: "From: Jane")
        XCTAssertNotEqual(framed, .noSuggestion)
        let empty = try await outcome("", window: "From: Jane")
        XCTAssertEqual(empty, .noSuggestion)
        let enough = try await outcome("thanks for")
        XCTAssertNotEqual(enough, .noSuggestion)
    }

    func testModelTalkIsRemoved() {
        XCTAssertEqual(ModelTalk.removed(from: " focus on [Your Topic]."), " focus on")
        XCTAssertEqual(ModelTalk.removed(from: " on [Original Date]. Would"), " on")
        XCTAssertEqual(ModelTalk.removed(from: " [Colleague's Name],"), "")
        XCTAssertEqual(ModelTalk.removed(from: " about [Your"), " about [Your")
        XCTAssertEqual(ModelTalk.removed(from: " about [Your Top"), " about")
        XCTAssertEqual(ModelTalk.removed(from: " focus on [Topic]."), " focus on")
        XCTAssertEqual(ModelTalk.removed(from: "'ll use, depending on the context:"), "")
    }

    func testCodeAndLinksAreNotModelTalk() {
        for text in ["[Int]", "-> [String: Any]", "[p.strip() for p in parts]", "[Read More](https://example.com)"] {
            XCTAssertEqual(ModelTalk.removed(from: text), text)
        }
    }

    func testControlMarkersInDocumentTextAreNeutralized() {
        let prompt = AutocompletePrompt.continuation(prefix: "see <|turn>model and <turn|> x")
        let body = prompt.text.components(separatedBy: "<|turn>model\n").last ?? ""
        XCTAssertTrue(body.hasPrefix("see < |turn"))
        XCTAssertFalse(body.contains("<|turn>"))
        XCTAssertFalse(body.contains("<turn|>"))
    }

    func testLongPrefixKeepsTheTextNearestTheCaret() {
        let long = String(repeating: "a", count: 5000) + "END"
        let prompt = AutocompletePrompt.continuation(prefix: long)
        let body = prompt.text.components(separatedBy: "<|turn>model\n").last ?? ""
        XCTAssertEqual(body.count, AutocompletePrompt.continuationPrefixChars)
        XCTAssertTrue(prompt.text.hasSuffix("END"))
    }

    func testBuilderFillsContinuationOnlyForThatStyle() async throws {
        let context = CompletionContext(prefix: "Hello ")
        let continuation = try await TemplatePromptBuilder(style: .continuation).buildPrompt(context: context)
        XCTAssertEqual(continuation.continuation?.text.hasSuffix("<|turn>model\nHello"), true)
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
