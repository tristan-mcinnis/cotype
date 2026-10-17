import Foundation
import CotypeCore

/// Runs a set of evaluation cases through the full completion pipeline and
/// scores each one against accepted alternatives, forbidden-output rules, and
/// length caps.
///
/// The engine is injectable, so the same harness works against a deterministic
/// mock (CI, differential testing) or a real local/remote model. Everything else
/// in the pipeline is fixed to the canonical building blocks. Sanitization is
/// applied by `CompletionPipeline` via the shared `OutputSanitizer`, so the
/// scored `actual` exactly matches what the menu app would show/insert.
public struct EvalRunner {

    public init() {}

    /// Run every case and return one `EvalResult` per case, in the same order.
    /// A pipeline error is recorded as a `.failure` outcome for that case, not a
    /// thrown error — the harness always returns one row per case.
    public static func run(
        cases: [EvalCase],
        engine: InferenceEngine,
        customInstruction: String = "",
        style: PromptStyle = .default,
        length: SuggestionLength = .default,
        examples: String = ""
    ) async -> [EvalResult] {
        var results: [EvalResult] = []
        results.reserveCapacity(cases.count)

        for evalCase in cases {
            results.append(await run(
                case: evalCase,
                engine: engine,
                customInstruction: customInstruction,
                style: style,
                length: length,
                examples: examples
            ))
        }

        return results
    }

    /// Run a single case through the full pipeline and score it.
    public static func run(
        case evalCase: EvalCase,
        engine: InferenceEngine,
        customInstruction: String = "",
        style: PromptStyle = .default,
        length: SuggestionLength = .default,
        examples: String = ""
    ) async -> EvalResult {
        // `systemPrompt` is the author's custom style note for the instruction
        // lane; the continuation directive in front of it is fixed. The
        // continuation lane does not transmit `system`.
        // The eval composes exactly what the app sends: an empty custom
        // instruction means "no style note", never the legacy boilerplate.
        let system = AutocompletePrompt.system(
            for: style,
            customInstruction: customInstruction,
            length: length
        )
        var builder = TemplatePromptBuilder(
            systemTemplate: system,
            style: style
        )
        if !examples.isEmpty {
            builder.personalizationSummary = { examples }
        }
        let pipeline = CompletionPipeline(
            contextProvider: StaticContextProvider(),
            promptBuilder: builder,
            engine: engine,
            renderer: NoopRenderer(),
            inserter: PrintInserter()
        )

        let request = CompletionRequest(
            appIdentifier: "eval",
            prefix: evalCase.prefix,
            suffix: evalCase.suffix,
            language: evalCase.language,
            extra: evalCase.extra
        )

        do {
            let started = ContinuousClock.now
            let result = try await pipeline.completeWithOutcome(request)
            let elapsed = seconds(ContinuousClock.now - started)

            let actual = result.text
            let outcome: EvalOutcome = switch result.outcome {
            case .suggestion: .suggestion
            case .noSuggestion: .noSuggestion
            }

            let metrics = EvalMetrics.compute(
                actual: actual,
                expected: evalCase.expected,
                acceptedAlternatives: evalCase.acceptedAlternatives,
                forbiddenSubstrings: evalCase.forbiddenSubstrings,
                maxLength: evalCase.maxLength
            )

            return EvalResult(
                case: evalCase,
                actual: actual,
                rawOutput: result.rawText,
                metrics: metrics,
                outcome: outcome,
                duration: elapsed,
                timeToFirstToken: result.timings.timeToFirstToken,
                tokenCount: result.timings.tokenCount,
                tokensPerSecond: result.timings.tokensPerSecond
            )
        } catch {
            // The completion throws (load, decode, cancellation, context). Record
            // it as a distinct failure so no-suggestion is not conflated with it.
            var metrics = EvalMetrics.compute(
                actual: "",
                expected: evalCase.expected,
                acceptedAlternatives: evalCase.acceptedAlternatives,
                forbiddenSubstrings: evalCase.forbiddenSubstrings,
                maxLength: evalCase.maxLength
            )
            // A thrown generation is not a valid output.
            metrics = EvalMetrics(
                exactMatch: metrics.exactMatch,
                prefixMatch: 0,
                tokenF1: metrics.tokenF1,
                lengthRatio: metrics.lengthRatio,
                valid: false,
                matchedAlternative: metrics.matchedAlternative,
                forbiddenCount: metrics.forbiddenCount,
                hasForbiddenOutput: metrics.hasForbiddenOutput,
                isOverlong: metrics.isOverlong,
                editSimilarity: metrics.editSimilarity
            )
            return EvalResult(
                case: evalCase,
                actual: "",
                rawOutput: "",
                metrics: metrics,
                outcome: .failure(String(describing: error)),
                duration: 0,
                timeToFirstToken: 0,
                tokenCount: 0,
                tokensPerSecond: 0
            )
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
