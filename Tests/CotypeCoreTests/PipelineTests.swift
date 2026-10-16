import XCTest
@testable import CotypeCore

private final class RecordingRenderer: CompletionRenderer {
    var presented: [String] = []
    var clearCount = 0
    func present(_ candidate: String, for request: CompletionRequest) { presented.append(candidate) }
    func clear() { clearCount += 1 }
}

private final class RecordingInserter: CompletionInserter {
    var inserted: [String] = []
    func insert(_ text: String) async throws { inserted.append(text) }
}

/// An engine that streams a partial then yields `.end` "normally" (as a real
/// engine may after cancellation) without throwing `CancellationError`. The test
/// drives `finishNormally()` after cancelling the pipeline task, so the loop
/// exits normally and the pipeline's post-loop cancellation guard must catch it.
private final class ControlledEndEngine: InferenceEngine, @unchecked Sendable {
    var name: String { "controlled-end" }
    private var continuation: AsyncThrowingStream<CompletionEvent, Error>.Continuation?
    private let lock = NSLock()

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            continuation.yield(.token("partial"))
        }
    }

    func finishNormally() {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(.end)
        c?.finish()
    }
}

/// Emits a fixed response as a single token, preserving leading whitespace that
/// the space-splitting `MockInferenceEngine` would drop.
private struct SingleChunkEngine: InferenceEngine {
    let name = "single-chunk"
    let response: String
    init(_ response: String) { self.response = response }
    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.yield(.end)
            continuation.finish()
        }
    }
}

final class PipelineTests: XCTestCase {

    func testPipelineProducesFullCompletion() async throws {
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "hello world"),
            renderer: NoopRenderer(),
            inserter: PrintInserter()
        )
        let result = try await pipeline.complete(
            CompletionRequest(prefix: "say ")
        )
        XCTAssertEqual(result, "hello world")
    }

    func testAcceptInsertsAndClearsRenderedCandidate() async throws {
        let renderer = RecordingRenderer()
        let inserter = RecordingInserter()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            renderer: renderer,
            inserter: inserter
        )

        let result = try await pipeline.complete(CompletionRequest(prefix: "say "))
        try await pipeline.accept(result)

        XCTAssertEqual(inserter.inserted, ["hello"])
        XCTAssertEqual(renderer.presented.last, "hello")
        XCTAssertEqual(renderer.clearCount, 1)
    }

    func testAcceptIgnoresEmptyCandidate() async throws {
        let renderer = RecordingRenderer()
        let inserter = RecordingInserter()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "", wordDelayNanoseconds: 0),
            renderer: renderer,
            inserter: inserter
        )

        try await pipeline.accept("")
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(renderer.clearCount, 0)
    }

    func testTemplatePromptBuilderSubstitutesPlaceholders() async throws {
        let builder = TemplatePromptBuilder(
            systemTemplate: "system for {{language}}",
            userTemplate: "prefix={{prefix}} suffix={{suffix}}"
        )
        let prompt = try await builder.buildPrompt(context: CompletionContext(
            prefix: "abc",
            suffix: "xyz",
            language: "swift"
        ))
        XCTAssertEqual(prompt.system, "system for swift")
        XCTAssertEqual(prompt.user, "prefix=abc suffix=xyz")
        XCTAssertEqual(prompt.suffix, "xyz")
    }

    func testTemplatePromptBuilderSubstitutesExtraValues() async throws {
        let builder = TemplatePromptBuilder(
            systemTemplate: "app={{appName}}",
            userTemplate: "selection={{selectedText}}"
        )
        let prompt = try await builder.buildPrompt(context: CompletionContext(
            prefix: "",
            extra: ["appName": "Mail", "selectedText": "hello"]
        ))
        XCTAssertEqual(prompt.system, "app=Mail")
        XCTAssertEqual(prompt.user, "selection=hello")
    }

    func testDefaultPromptIncludesWindowContextAndCurrentFieldAsSeparateInputs() async throws {
        let builder = TemplatePromptBuilder()
        let prompt = try await builder.buildPrompt(context: CompletionContext(
            prefix: "I think the key point is",
            appIdentifier: "com.example.chat",
            extra: ["windowContext": "Earlier message about keeping the scope narrow."]
        ))

        XCTAssertTrue(prompt.user.contains("<on_screen>"))
        XCTAssertTrue(prompt.user.contains("Earlier message about keeping the scope narrow."))
        XCTAssertTrue(prompt.user.hasSuffix("Output:"))
        XCTAssertTrue(prompt.user.contains("I think the key point is"))
        XCTAssertTrue(prompt.user.contains("Input: "))
    }

    func testDefaultPromptStaysRawWhenWindowContextIsUnavailable() async throws {
        let prompt = try await TemplatePromptBuilder().buildPrompt(
            context: CompletionContext(prefix: "continue this")
        )
        XCTAssertEqual(prompt.user, "Input: continue this\nOutput:")
    }

    func testPipelineSanitizesControlTokenAndPromptEcho() async throws {
        // A whitespace-stable prefix so the mock's split/join does not alter it.
        let prefix = "calculate the total of "
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: prefix + "5<|turn>rest", wordDelayNanoseconds: 0),
            renderer: NoopRenderer(),
            inserter: PrintInserter()
        )
        let result = try await pipeline.complete(CompletionRequest(prefix: prefix))
        XCTAssertEqual(result, "5")
    }

    func testPipelineReportsNoSuggestionWhenOnlyControlToken() async throws {
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "<|turn>model\n", wordDelayNanoseconds: 0),
            renderer: NoopRenderer(),
            inserter: PrintInserter()
        )
        let outcome = try await pipeline.completeWithOutcome(CompletionRequest(prefix: "hello"))
        XCTAssertEqual(outcome.outcome, .noSuggestion)
        XCTAssertEqual(outcome.text, "")
    }

    func testPipelineTracksTTFTAndTokenCount() async throws {
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "a b c", wordDelayNanoseconds: 5_000_000),
            renderer: NoopRenderer(),
            inserter: PrintInserter()
        )
        let outcome = try await pipeline.completeWithOutcome(CompletionRequest(prefix: "say "))
        XCTAssertEqual(outcome.outcome, .suggestion("a b c"))
        XCTAssertEqual(outcome.timings.tokenCount, 3)
        XCTAssertGreaterThanOrEqual(outcome.timings.timeToFirstToken, 0)
        XCTAssertGreaterThan(outcome.timings.tokensPerSecond, 0)
    }

    // MARK: - Cancellation (never finalize a partial buffer, never present before
    // the sanitizer)

    func testPipelineDoesNotFinalizePartialBufferOnCancellation() async throws {
        let renderer = RecordingRenderer()
        let engine = ControlledEndEngine()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: engine,
            renderer: renderer,
            inserter: PrintInserter()
        )
        let task = Task {
            try await pipeline.completeWithOutcome(CompletionRequest(prefix: "say "))
        }

        // Wait for the partial to stream, then cancel mid-generation.
        let deadline = Date().addingTimeInterval(3)
        while renderer.presented.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(renderer.presented.last, "partial")

        task.cancel()
        engine.finishNormally() // engine breaks "normally" (yields .end)

        do {
            _ = try await task.value
            XCTFail("a cancelled generation must not be finalized as a candidate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // The partial render was cleared, never treated as a finished candidate.
        XCTAssertGreaterThanOrEqual(renderer.clearCount, 1)
    }

    func testPipelineThrowsCancellationWhenCancelledBeforeStreaming() async {
        let renderer = RecordingRenderer()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "hello world", wordDelayNanoseconds: 20_000_000),
            renderer: renderer,
            inserter: PrintInserter()
        )
        let task = Task {
            try await pipeline.completeWithOutcome(CompletionRequest(prefix: "say "))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(renderer.clearCount, 1)
    }

    func testPipelineSanitizesStreamedOutputBeforePresentation() async throws {
        // The mock streams raw tokens that include forbidden Gemma markers. The
        // canonical sanitizer must run before the renderer ever sees a token, so
        // a control token can never be presented, even transiently.
        let renderer = RecordingRenderer()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "hello <|turn> world", wordDelayNanoseconds: 0),
            renderer: renderer,
            inserter: PrintInserter()
        )

        let result = try await pipeline.complete(CompletionRequest(prefix: "say hello"))

        XCTAssertEqual(result, "hello")
        XCTAssertFalse(renderer.presented.isEmpty, "the renderer must receive streamed candidates")
        for presented in renderer.presented {
            XCTAssertFalse(presented.contains("<|turn>"), "streaming must present sanitized output: \(presented)")
            XCTAssertFalse(presented.contains("<turn|>"), "streaming must present sanitized output: \(presented)")
        }
        // The final sanitized candidate is rendered last.
        XCTAssertEqual(renderer.presented.last, "hello")
    }

    func testPipelineRendersFinalSanitizedCandidate() async throws {
        // A prompt echo that survives a single pass: the mock re-emits the whole
        // prompt tail. The final render must present the echo-stripped result
        // (i.e. the actual continuation), not the raw engine output. The prefix
        // uses single spaces so the mock's split/join keeps it byte-stable and
        // the echo detector can recognize it.
        let prefix = "calculate the total of "
        let renderer = RecordingRenderer()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: prefix + "42", wordDelayNanoseconds: 0),
            renderer: renderer,
            inserter: PrintInserter()
        )

        let result = try await pipeline.complete(CompletionRequest(prefix: prefix))

        XCTAssertEqual(result, "42")
        XCTAssertEqual(renderer.presented.last, "42", "the final present must be the sanitized candidate")
    }

    func testPipelinePreservesMeaningfulLeadingWhitespaceForTypeThrough() async throws {
        // A leading-space candidate (the "leading-space ghost") must survive the
        // pipeline so type-through inserts "hello dog", not "hellodog". The
        // prompt prefix ends in a non-whitespace char, so the space is a boundary.
        let renderer = RecordingRenderer()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: SingleChunkEngine(" dog"),
            renderer: renderer,
            inserter: PrintInserter()
        )

        let result = try await pipeline.complete(CompletionRequest(prefix: "The lazy"))

        XCTAssertEqual(result, " dog")
        XCTAssertEqual(renderer.presented.last, " dog", "the final render must keep the leading space")
    }

    func testPipelineDropsDoubledLeadingSpaceWhenPrefixEndsInSpace() async throws {
        // The prefix already ends in a space, so a candidate leading space would
        // double it; the pipeline must drop the redundant separator.
        let renderer = RecordingRenderer()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: SingleChunkEngine(" dog"),
            renderer: renderer,
            inserter: PrintInserter()
        )

        let result = try await pipeline.complete(CompletionRequest(prefix: "The quick brown fox jumps over the lazy "))

        XCTAssertEqual(result, "dog")
        XCTAssertEqual(renderer.presented.last, "dog")
    }

    func testPipelineClearsRendererWhenNothingUsable() async throws {
        let renderer = RecordingRenderer()
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "<|turn>model\n", wordDelayNanoseconds: 0),
            renderer: renderer,
            inserter: PrintInserter()
        )

        let outcome = try await pipeline.completeWithOutcome(CompletionRequest(prefix: "hello"))

        XCTAssertEqual(outcome.outcome, .noSuggestion)
        XCTAssertGreaterThanOrEqual(renderer.clearCount, 1, "a no-suggestion finish must clear ghost text")
    }

    func testPipelineEmitsEventsAtEachPhase() async throws {
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: TemplatePromptBuilder(),
            engine: MockInferenceEngine(response: "x", wordDelayNanoseconds: 0),
            renderer: NoopRenderer(),
            inserter: PrintInserter()
        )
        var phases: [CompletionPhase] = []
        let expectation = expectation(description: "events")
        let cancellable = pipeline.events.sink { phases.append($0.phase) }
        Task {
            _ = try? await pipeline.complete(CompletionRequest(prefix: "p"))
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 5)
        cancellable.cancel()
        for phase in [CompletionPhase.trigger, .context, .prompt, .inference] {
            XCTAssertTrue(phases.contains(phase), "missing \(phase)")
        }
    }
}
