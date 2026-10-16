import XCTest
@testable import CotypeCore

/// Streams scripted chunks and records how many the pipeline consumed.
private final class ChunkEngine: InferenceEngine, @unchecked Sendable {
    let name = "chunks"
    private let chunks: [String]
    private let lock = NSLock()
    private var _sent = 0
    init(_ chunks: [String]) { self.chunks = chunks }
    var sent: Int { lock.withLock { _sent } }

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                lock.withLock { _sent += 1 }
                continuation.yield(.token(chunk))
            }
            continuation.yield(.end)
            continuation.finish()
        }
    }
}

/// Stopping the stream early must never change the candidate. The reference
/// is what the pipeline produced before the early stop: the final candidate
/// shaped from the whole generation.
final class EarlyStopTests: XCTestCase {

    private static let prefixes = [
        "Let me get back to you by",
        "Let me get back to you by ",
        "Do you have any questi",
        "The meeting is at 3",
        "The end.",
        "Regarding order ",
        "return ",
        "[Cotype](https://github.com/",
        "print(\"hello, ",
        "我们下周一可以",
        "Hi Sam,\n",
        "Thanks for the update. I will send the revised deck to the whole team first thing tomorrow morning so",
    ]
    private static let suffixes = ["", "\")", " the end of the day", "th * height", "\nBest,"]
    private static let fragments = [
        " the end of the day", " and then we can talk", " about the plan", "ons about the plan?",
        " order number AX-2048 is late", " Error() when it fails", "tristan/cotype)),", " world\")",
        ". It was fine and", "! Great news, thanks", "开个会讨论一下吗？然后", "pm tomorrow at the office",
        "\n\nNext paragraph", "<|turn>model\nsure", "<|channel>thought<channel|> real words here",
        "Output: the answer is here", " soon", " x y z w v u", "```swift\nlet a = 1", "\n", " ", "",
    ]

    func testStoppingEarlyNeverChangesTheCandidate() async throws {
        var rng = SplitMix(seed: 0xC07E)
        var mismatches: [String] = []
        var stopped = 0
        var cases = 0
        for style in PromptStyle.allCases {
        for prefix in Self.prefixes {
            for suffix in Self.suffixes {
                for _ in 0..<40 {
                    let output = Self.output(prefix: prefix, suffix: suffix, rng: &rng)
                    let chunks = Self.chunk(output, rng: &rng)
                    let maxWords = [1, 2, 3, 4, 6, 16][Int(rng.next() % 6)]
                    let expected = Self.reference(
                        output, prefix: prefix, suffix: suffix, maxWords: maxWords,
                        modelSawBoundary: style == .continuation
                    )

                    let engine = ChunkEngine(chunks)
                    let pipeline = CompletionPipeline(
                        contextProvider: StaticContextProvider(),
                        promptBuilder: TemplatePromptBuilder(style: style),
                        engine: engine,
                        renderer: NoopRenderer(),
                        inserter: PrintInserter()
                    )
                    pipeline.maxWords = maxWords
                    let result = try await pipeline.completeWithOutcome(
                        CompletionRequest(prefix: prefix, suffix: suffix)
                    )
                    cases += 1
                    if result.timings.stoppedEarly { stopped += 1 }
                    if result.text != expected {
                        mismatches.append("\(style) early=\(result.timings.stoppedEarly) prefix=\(prefix.debugDescription) suffix=\(suffix.debugDescription) max=\(maxWords) chunks=\(chunks.debugDescription): got \(result.text.debugDescription), want \(expected.debugDescription)")
                    }
                }
            }
        }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) of \(cases) differ:\n" + mismatches.prefix(14).joined(separator: "\n"))
        XCTAssertGreaterThan(stopped, cases / 4, "the early stop should fire on a good share of long outputs")
        print("early stop: \(stopped) of \(cases) cases stopped early, \(mismatches.count) differ")
    }

    func testStopsOnceAWordPastTheCapHasBegun() async throws {
        let engine = ChunkEngine([" move", " the", " meeting", " to", " Friday", " at", " noon", " if", " you", " can"])
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(), promptBuilder: TemplatePromptBuilder(),
            engine: engine, renderer: NoopRenderer(), inserter: PrintInserter()
        )
        pipeline.maxWords = 3
        let result = try await pipeline.completeWithOutcome(CompletionRequest(prefix: "I think we should"))
        XCTAssertEqual(result.text, " move the meeting")
        XCTAssertTrue(result.timings.stoppedEarly)
        XCTAssertEqual(result.timings.tokenCount, 4, "consumes the fourth word's first token, then stops")
    }

    func testKeepsGoingWhileTheOutputMayStillBeAPromptEcho() async throws {
        // The first words repeat the end of the prompt; only the whole output
        // shows that they are an echo to strip.
        let prefix = "Please review the attached budget before the call tomorrow"
        let engine = ChunkEngine([" review", " the", " attached", " budget", " before", " the", " call", " tomorrow", " and", " reply"])
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(), promptBuilder: TemplatePromptBuilder(),
            engine: engine, renderer: NoopRenderer(), inserter: PrintInserter()
        )
        pipeline.maxWords = 3
        let result = try await pipeline.completeWithOutcome(CompletionRequest(prefix: prefix))
        XCTAssertEqual(result.text, Self.reference(
            " review the attached budget before the call tomorrow and reply",
            prefix: prefix, suffix: "", maxWords: 3
        ))
        XCTAssertGreaterThanOrEqual(result.timings.tokenCount, 9, "must read past the echo before deciding")
    }

    func testStopsAtTheEndOfTheSentence() async throws {
        let engine = ChunkEngine([" soon", ".", " Then", " more", " text", " here"])
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(), promptBuilder: TemplatePromptBuilder(),
            engine: engine, renderer: NoopRenderer(), inserter: PrintInserter()
        )
        pipeline.maxWords = 16
        let result = try await pipeline.completeWithOutcome(CompletionRequest(prefix: "I will send it"))
        XCTAssertEqual(result.text, " soon.")
        XCTAssertTrue(result.timings.stoppedEarly)
        XCTAssertEqual(result.timings.tokenCount, 3)
    }

    /// Found by the fuzz above: a sentence can end before the repeated-word
    /// rule has seen a second word, and a lone "<" or "`" can still become a
    /// cut token that shortens the end and exposes a suffix duplicate.
    func testWaitsForRulesThatStillDependOnLaterText() async throws {
        let runs: [(prefix: String, suffix: String, style: PromptStyle, max: Int, chunks: [String])] = [
            ("Regarding order ", "", .instruction, 6, ["order", " 开个会讨论", "一", "下吗？然后", ". ", "It wa", "s f"]),
            ("[Cotype](https://github.com/", " the end of the day", .instruction, 6,
             [" the e", "nd ", "of", " th ", "t", "he end", " of t<", "|t", "urn>", "mod"]),
            ("Hi Sam,\n", " the end of the day", .continuation, 3,
             [" the", " ", "end of", " ", "the ", "d", "ay`", "`", "`", "swi", "ft\nl", "et "]),
        ]
        for run in runs {
            let pipeline = CompletionPipeline(
                contextProvider: StaticContextProvider(),
                promptBuilder: TemplatePromptBuilder(style: run.style),
                engine: ChunkEngine(run.chunks), renderer: NoopRenderer(), inserter: PrintInserter()
            )
            pipeline.maxWords = run.max
            let result = try await pipeline.completeWithOutcome(CompletionRequest(prefix: run.prefix, suffix: run.suffix))
            XCTAssertEqual(result.text, Self.reference(
                run.chunks.joined(), prefix: run.prefix, suffix: run.suffix, maxWords: run.max,
                modelSawBoundary: run.style == .continuation
            ), run.prefix)
        }
    }

    // MARK: - Helpers

    static func reference(
        _ output: String, prefix: String, suffix: String, maxWords: Int, modelSawBoundary: Bool = true
    ) -> String {
        if CaretBoundary.isInsideWord(prefix: prefix, suffix: suffix) { return "" }
        let sanitized = OutputSanitizer().process(output, promptTail: prefix, suffix: suffix)
        let joined = CaretBoundary.reconcile(prefix: prefix, candidate: sanitized.text, isWord: nil, modelSawBoundary: modelSawBoundary)
        return CompletionPipeline.finalize(joined, prefix: prefix, maxWords: maxWords)
    }

    /// A model output built from fragments, echoes of the prompt tail, and the
    /// start of the suffix.
    private static func output(prefix: String, suffix: String, rng: inout SplitMix) -> String {
        var text = ""
        let parts = 1 + Int(rng.next() % 4)
        for _ in 0..<parts {
            switch rng.next() % 5 {
            case 0:
                // Echo a tail slice of the prompt (partial or whole).
                let count = prefix.count
                let take = count == 0 ? 0 : 1 + Int(rng.next() % UInt64(count))
                text += String(prefix.suffix(take))
            case 1:
                text += String(suffix.prefix(Int(rng.next() % UInt64(suffix.count + 1))))
            default:
                text += fragments[Int(rng.next() % UInt64(fragments.count))]
            }
        }
        return text
    }

    /// Split into random 1-6 character chunks, like a tokenizer would.
    private static func chunk(_ text: String, rng: inout SplitMix) -> [String] {
        var chunks: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let size = 1 + Int(rng.next() % 6)
            chunks.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return chunks
    }
}

/// Deterministic generator so a failure reproduces.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
