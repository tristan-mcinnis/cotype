import XCTest
@testable import CotypeCore

/// The advertised controls must reach the request the chosen lane actually
/// sends, and must NOT reach a lane they would damage. The continuation lane's
/// measured shape is "keep writing the document": raw notes and
/// `input -> output` examples leak into completions, so they stay in the
/// instruction lane's system message. These tests serialize the real request.
final class PromptDeliveryTests: XCTestCase {

    private let prefix = "Thanks for the update — I will "

    private func prompt(
        prefix customPrefix: String? = nil,
        style: PromptStyle = .continuation,
        systemPrompt: String = AutocompletePrompt.defaultSystem,
        facts: String = "",
        examples: String = "",
        windowContext: String = "",
        length: SuggestionLength = .default
    ) async throws -> Prompt {
        let custom = systemPrompt == AutocompletePrompt.defaultSystem ? "" : systemPrompt
        var builder = TemplatePromptBuilder(
            systemTemplate: AutocompletePrompt.system(
                for: style,
                customInstruction: custom,
                length: length
            ),
            style: style,
            personalFacts: facts
        )
        if !examples.isEmpty {
            builder.personalizationSummary = { examples }
        }
        var extra: [String: String] = [:]
        if !windowContext.isEmpty { extra["windowContext"] = windowContext }
        return try await builder.buildPrompt(
            context: CompletionContext(prefix: customPrefix ?? prefix, extra: extra)
        )
    }

    private func requestBody(_ prompt: Prompt) throws -> [String: Any] {
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "http://127.0.0.1:8079/v1")!,
            model: "gemma-it",
            maxTokens: SuggestionLength.default.maxTokens
        )
        let request = try engine.continuationRequest(XCTUnwrap(prompt.continuation))
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: The default lane keeps its measured shape

    func testDefaultInstallSendsTheMeasuredDocumentUnchanged() async throws {
        let prompt = try await prompt()
        let continuation = try XCTUnwrap(prompt.continuation)
        // Token healing moves the caret's single trailing space into
        // `requiredLeading`; combined they end in exactly the typed text.
        XCTAssertTrue((continuation.text + continuation.requiredLeading).hasSuffix("<|turn>model\n" + prefix))
        XCTAssertFalse(continuation.text.contains("<context>"))
        XCTAssertFalse(continuation.text.contains("You are an inline autocomplete engine"))
    }

    func testPersonalFactsReachTheContinuationRequest() async throws {
        let prompt = try await prompt(prefix: "My email is ", facts: "Name: Sam Rivera\nEmail: sam@example.com")
        let sent = try XCTUnwrap(prompt.continuation?.text)
        XCTAssertTrue(sent.contains("sam@example.com"))
    }

    func testPersonalFactsStayOutOfTextThatDoesNotCallForThem() async throws {
        let prompt = try await prompt(facts: "Name: Sam Rivera\nEmail: sam@example.com")
        let sent = try XCTUnwrap(prompt.continuation?.text)
        XCTAssertFalse(sent.contains("Sam Rivera"))
    }

    /// Instructions would be continued as prose, not obeyed. They must not be in
    /// the continuation document even when they are saved.
    func testWritingInstructionsDoNotEnterTheContinuationRequest() async throws {
        let prompt = try await prompt(systemPrompt: "Write in British English. Never use exclamation marks.")
        let body = try requestBody(prompt)
        let sent = try XCTUnwrap(body["prompt"] as? String)
        XCTAssertFalse(sent.contains("British English"))
        XCTAssertFalse(sent.contains("Writing notes"))
    }

    /// The measured leak: `- input -> output` examples were imitated verbatim
    /// (arrows appeared in completions). They must never enter this lane.
    func testLearnedExamplesDoNotEnterTheContinuationRequest() async throws {
        let summary = "Examples from your accepted completions:\n- Thanks for the → update on the plan"
        let prompt = try await prompt(examples: summary)
        let sent = try XCTUnwrap(prompt.continuation?.text)
        XCTAssertFalse(sent.contains("accepted completions"))
        XCTAssertFalse(sent.contains("→"))
    }

    // MARK: The chat lane is a continuation directive, not an answering prompt

    func testChatSystemKeepsTheContinuationDirectiveFirst() {
        let composed = AutocompletePrompt.chatSystem(
            length: .medium,
            customStyle: "Never use exclamation marks."
        )
        XCTAssertTrue(composed.hasPrefix(AutocompletePrompt.chatSystem))
        XCTAssertTrue(composed.contains("Output ONLY the continuation"))
        XCTAssertTrue(composed.contains("Writing style: Never use exclamation marks."))
    }

    func testChatSystemWithoutAStyleNoteIsTheDirectivePlusLength() {
        XCTAssertEqual(
            AutocompletePrompt.chatSystem(length: .medium, customStyle: "   "),
            AutocompletePrompt.chatSystem + " " + SuggestionLength.medium.chatDirective
        )
    }

    /// The chat lane's word range must follow the Suggestion length setting,
    /// not a hardcoded range.
    func testChatSystemUsesTheSharedLengthDirective() {
        for length in SuggestionLength.allCases {
            let system = AutocompletePrompt.system(for: .instruction, customInstruction: "", length: length)
            XCTAssertTrue(system.contains(length.chatDirective), "\(length) must carry its own directive")
            for other in SuggestionLength.allCases where other != length {
                XCTAssertFalse(system.contains(other.chatDirective), "\(length) must not carry \(other)'s directive")
            }
        }
        XCTAssertFalse(AutocompletePrompt.chatSystem.contains("2-6 words"), "no hardcoded range")
    }

    // MARK: The instruction lane carries them in the model-supported place

    func testInstructionLaneCarriesTheCustomPromptAsTheSystemMessage() async throws {
        let prompt = try await prompt(
            style: .instruction,
            systemPrompt: "Write in British English. Never use exclamation marks."
        )
        XCTAssertNil(prompt.continuation)
        XCTAssertTrue(prompt.system.contains("inline autocomplete engine"))
        XCTAssertTrue(prompt.system.contains("British English"))
        XCTAssertFalse(prompt.user.contains("British English"))
        XCTAssertEqual(prompt.user, prefix, "the chat lane continues the raw text, not an Input/Output scaffold")
    }

    func testInstructionLaneCarriesLearnedExamplesOnlyInTheSystemMessage() async throws {
        let summary = "Examples from your accepted completions:\n- Thanks for the → update on the plan"
        let prompt = try await prompt(style: .instruction, examples: summary)
        XCTAssertTrue(prompt.system.contains("accepted completions"))
        XCTAssertFalse(prompt.user.contains("accepted completions"))
        XCTAssertFalse(prompt.user.contains("→"))
    }

    // MARK: Context budget is per part, so facts cannot be evicted

    func testLongWindowContextCannotEvictTheAuthorsFacts() async throws {
        let facts = String(repeating: "fact line\n", count: 80) // > 600 chars
        let window = String(repeating: "w", count: 5000)
        let prompt = try await prompt(prefix: "My email is ", facts: facts, windowContext: window)
        let sent = try XCTUnwrap(prompt.continuation?.text)

        XCTAssertTrue(sent.contains("fact line"), "facts are the first-priority block")
        XCTAssertLessThanOrEqual(contextChars(sent), AutocompletePrompt.continuationContextChars)
        XCTAssertTrue(sent.contains("wwww"), "window context still contributes")
    }

    func testFactsAloneAreCappedAndWindowFillsTheRemainder() async throws {
        let facts = String(repeating: "a", count: 5000)
        let window = String(repeating: "b", count: 5000)
        let prompt = try await prompt(prefix: "My email is ", facts: facts, windowContext: window)
        let sent = try XCTUnwrap(prompt.continuation?.text)
        XCTAssertLessThanOrEqual(contextChars(sent), AutocompletePrompt.continuationContextChars)
        XCTAssertGreaterThan(contextChars(sent), AutocompletePrompt.continuationFactsChars,
                             "the window uses the remaining budget instead of being dropped")
    }

    func testWindowOnlyContextUsesTheWholeBudget() async throws {
        let window = String(repeating: "z", count: 5000)
        let prompt = try await prompt(windowContext: window)
        let sent = try XCTUnwrap(prompt.continuation?.text)
        XCTAssertEqual(contextChars(sent), AutocompletePrompt.continuationContextChars)
    }

    /// Characters of facts and window text in the task turn, headings excluded.
    private func contextChars(_ sent: String) -> Int {
        let task = sent.components(separatedBy: "<turn|>").first ?? ""
        return task
            .replacingOccurrences(of: "<|turn>user\n", with: "")
            .replacingOccurrences(of: AutocompletePrompt.continuationReplyTask + "\n", with: "")
            .replacingOccurrences(of: "\n\n" + AutocompletePrompt.continuationFactsHeading + "\n", with: "")
            .count
    }

    // MARK: Transmission budget

    func testRequestBodyCarriesTheEffectiveBudget() async throws {
        let defaults = makeUserDefaults()
        defaults.set(SuggestionLength.long.rawValue, forKey: SuggestionLength.defaultsKey)
        let budget = TokenBudget.effective(defaults)
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "http://127.0.0.1:8079/v1")!,
            model: "gemma-it",
            maxTokens: budget.tokens
        )
        let prompt = try await prompt()
        let request = try engine.continuationRequest(XCTUnwrap(prompt.continuation))
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["max_tokens"] as? Int, budget.tokens)
        XCTAssertEqual(json["max_tokens"] as? Int, SuggestionLength.long.maxTokens)
    }
}
