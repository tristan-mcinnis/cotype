import Foundation
import Combine

/// Orchestrates the completion loop by composing pluggable stages.
///
/// Stages are protocols, so every element of the loop is replaceable. A
/// `PassthroughSubject` emits a `PipelineEvent` at each stage boundary, giving
/// full visibility into what was captured, built, streamed, and inserted.
public final class CompletionPipeline {

    public let contextProvider: ContextProvider
    public let promptBuilder: PromptBuilder
    public let engine: InferenceEngine
    public let renderer: CompletionRenderer
    public let inserter: CompletionInserter

    /// Spelling oracle for `CaretBoundary` (is this a real word?). The app sets
    /// the system spell checker; nil keeps only the dictionary-free rules.
    public var wordChecker: ((String) -> Bool)?

    /// Word cap on a suggestion (see `SuggestionLength`).
    public var maxWords = 4

    /// Observability stream. Subscribe to inspect or tee the loop.
    public let events = PassthroughSubject<PipelineEvent, Never>()

    public init(
        contextProvider: ContextProvider,
        promptBuilder: PromptBuilder,
        engine: InferenceEngine,
        renderer: CompletionRenderer,
        inserter: CompletionInserter
    ) {
        self.contextProvider = contextProvider
        self.promptBuilder = promptBuilder
        self.engine = engine
        self.renderer = renderer
        self.inserter = inserter
    }

    /// Run one completion end-to-end. Returns the sanitized candidate text.
    /// Emits observability events at every boundary.
    @discardableResult
    public func complete(_ request: CompletionRequest) async throws -> String {
        try await completeWithOutcome(request).text
    }

    /// The outcome and timing from the most recent `complete` run, for callers
    /// (e.g. the eval) that need more than the plain candidate string.
    public private(set) var lastOutcome: CompletionOutcome = .noSuggestion
    public private(set) var lastTimings = PipelineTimings()

    /// Run one completion end-to-end, returning the sanitized text, the raw
    /// (pre-sanitization) engine output, the explicit outcome, and generation
    /// timing. This is the single path shared by the menu app and the eval, so
    /// both apply the same canonical sanitizer.
    @discardableResult
    public func completeWithOutcome(_ request: CompletionRequest) async throws -> (text: String, rawText: String, outcome: CompletionOutcome, timings: PipelineTimings) {
        emit(.trigger, "request received for \(request.appIdentifier)")

        let context = try await contextProvider.provideContext(for: request)
        emit(.context, "context captured (\(context.prefix.count) prefix chars)", context)

        // The caret is inside a word the suffix already finishes: abstain
        // without spending a generation.
        if CaretBoundary.isInsideWord(prefix: context.prefix, suffix: context.suffix) {
            CotypeLog.loop.debug("abstain: caret inside a word")
            renderer.clear()
            lastOutcome = .noSuggestion
            lastTimings = PipelineTimings()
            emit(.inference, "abstained (caret inside a word)", "")
            return ("", "", .noSuggestion, PipelineTimings())
        }

        let prompt = try await promptBuilder.buildPrompt(context: context)
        emit(.prompt, "prompt built (system=\(prompt.system.count) user=\(prompt.user.count))", prompt)

        // The canonical sanitizer runs at every boundary so the renderer only
        // ever sees sanitized output. A control token / stop sequence split
        // across engine tokens must never be presented, even transiently.
        let sanitizer = OutputSanitizer()
        let modelSawBoundary = prompt.continuation != nil

        var buffer = ""
        var timings = PipelineTimings()
        var sawFirstToken = false
        let requestStart = ContinuousClock.now
        var generationStart = requestStart

        do {
            generation: for try await event in engine.stream(prompt: prompt) {
                try Task.checkCancellation()
                switch event {
                case .token(let token):
                    if !sawFirstToken {
                        sawFirstToken = true
                        generationStart = ContinuousClock.now
                        timings.timeToFirstToken = Self.seconds(ContinuousClock.now - requestStart)
                    }
                    buffer += token
                    timings.tokenCount += 1
                    // Fail closed on cancellation: never present a partial buffer
                    // that will not be completed (a cancelled engine may still
                    // break its stream "normally").
                    guard !Task.isCancelled else {
                        renderer.clear()
                        throw CancellationError()
                    }
                    // Present only sanitized output so a control token / stop
                    // sequence split across tokens is never shown, even transiently.
                    let processed = sanitizer.process(
                        buffer,
                        promptTail: context.prefix,
                        suffix: context.suffix
                    )
                    let joined = CaretBoundary.reconcile(
                        prefix: context.prefix, candidate: processed.text, isWord: wordChecker,
                        modelSawBoundary: modelSawBoundary
                    )
                    renderer.present(Self.finalize(joined, prefix: context.prefix, maxWords: maxWords), for: request)
                    // Stop as soon as more text cannot change the candidate:
                    // the Tab window opens at the end of the stream, and the
                    // tokens after the cap were only thrown away.
                    if Self.isFixed(joined, prefix: context.prefix, maxWords: maxWords),
                       sanitizer.isSettled(buffer, promptTail: context.prefix) {
                        timings.stoppedEarly = true
                        break generation
                    }
                case .end:
                    break
                }
            }
            // Even if an engine ends normally on cancellation, do not finalize a
            // partial buffer as a finished candidate.
            try Task.checkCancellation()
        } catch {
            renderer.clear()
            throw error
        }

        timings.generationTime = Self.seconds(ContinuousClock.now - generationStart)

        let sanitized = sanitizer.process(buffer, promptTail: context.prefix, suffix: context.suffix)
        let candidate = Self.finalize(
            CaretBoundary.reconcile(
                prefix: context.prefix, candidate: sanitized.text, isWord: wordChecker,
                modelSawBoundary: modelSawBoundary
            ),
            prefix: context.prefix,
            maxWords: maxWords
        )
        let isNoSuggestion = sanitized.isNoSuggestion || candidate.isEmpty
        let outcome: CompletionOutcome = isNoSuggestion ? .noSuggestion : .suggestion(candidate)

        // Render the final sanitized candidate (or clear ghost text when it
        // produced nothing usable), so what is shown always matches what the
        // evaluator scores and the inserter would insert.
        if isNoSuggestion {
            renderer.clear()
        } else {
            renderer.present(candidate, for: request)
        }

        lastOutcome = outcome
        lastTimings = timings
        emit(.inference, "inference finished (\(candidate.count) chars)", candidate)
        return (candidate, buffer, outcome, timings)
    }

    /// The last shaping steps shared by streamed and final candidates: stay in
    /// the current sentence, then apply the word cap.
    static func finalize(_ joined: String, prefix: String, maxWords: Int) -> String {
        SuggestionWordLimiter.limit(
            CaretBoundary.limitToSentence(prefix: prefix, candidate: joined),
            maxWords: maxWords
        )
    }

    /// True when later text cannot change `finalize(joined)`: the sentence
    /// already ended inside the candidate, or a word past the cap has begun.
    /// Callers must also check `OutputSanitizer.isSettled`, which covers the
    /// sanitizer rules that look at the whole output.
    static func isFixed(_ joined: String, prefix: String, maxWords: Int) -> Bool {
        let sentence = CaretBoundary.limitToSentence(prefix: prefix, candidate: joined)
        guard !sentence.isEmpty else { return false }
        return sentence.count < joined.count
            || SuggestionWordLimiter.exceedsLimit(sentence, maxWords: maxWords)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let d = duration.components
        return TimeInterval(d.seconds) + TimeInterval(d.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Accept and commit the completion into the editor.
    public func accept(_ text: String) async throws {
        guard !text.isEmpty else { return }
        emit(.insert, "inserting \(text.count) chars", text)
        try await inserter.insert(text)
        renderer.clear()
    }

    /// Clear any rendered ghost text.
    public func cancel() {
        renderer.clear()
        emit(.render, "render cleared", nil)
    }

    private func emit(_ phase: CompletionPhase, _ summary: String, _ payload: Any? = nil) {
        events.send(PipelineEvent(phase: phase, summary: summary, payload: payload))
    }
}
