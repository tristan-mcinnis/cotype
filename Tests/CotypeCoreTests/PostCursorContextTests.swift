import XCTest
@testable import CotypeCore

/// Post-cursor text is captured and used to filter the candidate. The default
/// continuation prompt deliberately does not carry suffix prose; the instruction
/// lane carries it in a delimited block. These cases pin both halves.
final class PostCursorContextTests: XCTestCase {

    private final class RecordingRenderer: CompletionRenderer {
        var presented: [String] = []
        func present(_ candidate: String, for request: CompletionRequest) { presented.append(candidate) }
        func clear() {}
    }

    private final class RecordingInserter: CompletionInserter {
        var inserted: [String] = []
        func insert(_ text: String) async throws { inserted.append(text) }
    }

    /// One chunk, so leading whitespace survives (the word-splitting mock drops it).
    private struct SingleChunkEngine: InferenceEngine {
        let name = "single-chunk"
        let response: String
        func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.token(response))
                continuation.yield(.end)
                continuation.finish()
            }
        }
    }

    private func run(
        prefix: String,
        suffix: String,
        output: String,
        style: PromptStyle = .continuation
    ) async throws -> (text: String, calls: Int, prompt: Prompt) {
        let engine = CountingEngine(response: output)
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(style: style),
            engine: engine,
            renderer: RecordingRenderer(),
            inserter: RecordingInserter()
        )
        pipeline.maxWords = 6
        let result = try await pipeline.completeWithOutcome(
            CompletionRequest(appIdentifier: "com.example.editor", prefix: prefix, suffix: suffix)
        )
        return (result.text, engine.calls, engine.lastPrompt ?? Prompt(user: ""))
    }

    private final class CountingEngine: InferenceEngine, @unchecked Sendable {
        let name = "counting"
        let response: String
        private(set) var calls = 0
        private(set) var lastPrompt: Prompt?
        private let lock = NSLock()

        init(response: String) { self.response = response }

        func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
            lock.withLock {
                calls += 1
                lastPrompt = prompt
            }
            let response = response
            return AsyncThrowingStream { continuation in
                continuation.yield(.token(response))
                continuation.yield(.end)
                continuation.finish()
            }
        }
    }

    // MARK: Duplicate suppression

    func testNameAfterTheCursorIsNotDuplicated() async throws {
        let result = try await run(
            prefix: "Please loop in ",
            suffix: "Sam Rivera on the review.",
            output: " Sam Rivera on the review."
        )
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.calls, 1)
    }

    func testCJKAfterTheCursorIsNotDuplicated() async throws {
        let result = try await run(
            prefix: "我们周一",
            suffix: "开会讨论一下",
            output: "开会讨论一下"
        )
        XCTAssertEqual(result.text, "")
    }

    func testPunctuationAfterTheCursorIsNotDuplicated() async throws {
        let result = try await run(
            prefix: "The total is ",
            suffix: "(including tax).",
            output: "(including tax)."
        )
        XCTAssertEqual(result.text, "")
    }

    func testNonDuplicateContinuationIsKeptAndSuffixIsPreserved() async throws {
        let suffix = " on Friday."
        let result = try await run(
            prefix: "I will be there at ",
            suffix: suffix,
            output: "3pm"
        )
        XCTAssertEqual(result.text, "3pm")
        XCTAssertTrue(result.text.hasSuffix("3pm"))
        // Inserting the suggestion leaves the suffix exactly as typed.
        XCTAssertEqual("I will be there at " + result.text + suffix, "I will be there at 3pm on Friday.")
    }

    /// A caret inside a word the suffix already finishes abstains before any
    /// generation is spent. This is the partial-word case for a name fragment.
    func testPartialWordWithSuffixAbstainsWithoutGenerating() async throws {
        let result = try await run(
            prefix: "Ask Sam Riv",
            suffix: "era for the deck.",
            output: "era"
        )
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.calls, 0)
    }

    // MARK: Transmission decision

    func testContinuationPromptDoesNotCarrySuffixProse() async throws {
        let result = try await run(
            prefix: "Hello ",
            suffix: " (this text follows the caret)",
            output: "there"
        )
        let continuation = try XCTUnwrap(result.prompt.continuation)
        XCTAssertFalse(continuation.text.contains("this text follows the caret"))
        XCTAssertFalse(continuation.text.contains("<after_cursor>"))
    }

    func testInstructionLaneCarriesDelimitedPostCursorContext() async throws {
        let result = try await run(
            prefix: "Hello ",
            suffix: " (this text follows the caret)",
            output: "there",
            style: .instruction
        )
        XCTAssertNil(result.prompt.continuation)
        XCTAssertTrue(result.prompt.userWithSuffixContext.contains("<after_cursor>"))
        XCTAssertTrue(result.prompt.userWithSuffixContext.contains("this text follows the caret"))
    }
}
