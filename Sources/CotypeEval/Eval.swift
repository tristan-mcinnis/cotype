import Foundation

/// The explicit outcome of one evaluation case, scoring no-suggestion (abstain)
/// separately from a generation failure.
public enum EvalOutcome: Equatable, Codable {
    /// A usable completion was produced and sanitized.
    case suggestion
    /// The model produced nothing usable; abstaining was (or should have been)
    /// the result. Distinct from a generation *failure*.
    case noSuggestion
    /// The pipeline threw (engine load, decode, cancellation, etc.).
    case failure(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "suggestion": self = .suggestion
        case "noSuggestion": self = .noSuggestion
        default: self = raw.hasPrefix("failure:") ? .failure(String(raw.dropFirst("failure:".count))) : .failure(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .suggestion: try container.encode("suggestion")
        case .noSuggestion: try container.encode("noSuggestion")
        case .failure(let message): try container.encode("failure: \(message)")
        }
    }
}

/// A single, self-contained evaluation case.
///
/// `prefix` is the natural code/prose text typed before the cursor, `expected`
/// is the short continuation the harness scores against, and `suffix` is the
/// optional fill-in-the-middle context that follows the cursor.
///
/// A case no longer needs one arbitrary exact string: `acceptedAlternatives`
/// allow several equally-good continuations, `forbiddenSubstrings` make
/// echo/control-token leaks measurable, `maxLength` makes over-generation
/// measurable, and `rubricTags` let suites slice the scoreboard.
public struct EvalCase: Codable {
    /// Stable, human-readable identifier used in scoreboards and diffs.
    public var id: String
    /// Text before the cursor (what the engine is asked to complete).
    public var prefix: String
    /// Text after the cursor for fill-in-the-middle models.
    public var suffix: String
    /// Detected source language, when known.
    public var language: String?
    /// Additional prompt context, including bounded active-window text.
    public var extra: [String: String]
    /// The primary continuation we expect.
    public var expected: String
    /// Additional, equally-valid continuations.
    public var acceptedAlternatives: [String]
    /// Substrings that must never appear in the completion (echo, control
    /// tokens, code fences, secrets).
    public var forbiddenSubstrings: [String]
    /// Desired maximum length; exceeding it is over-generation.
    public var maxLength: Int?
    /// Free-form tags for slicing the scoreboard (prose, code, fill-middle, abstain).
    public var rubricTags: [String]

    public init(
        id: String,
        prefix: String,
        suffix: String = "",
        language: String? = nil,
        extra: [String: String] = [:],
        expected: String,
        acceptedAlternatives: [String] = [],
        forbiddenSubstrings: [String] = [],
        maxLength: Int? = nil,
        rubricTags: [String] = []
    ) {
        self.id = id
        self.prefix = prefix
        self.suffix = suffix
        self.language = language
        self.extra = extra
        self.expected = expected
        self.acceptedAlternatives = acceptedAlternatives
        self.forbiddenSubstrings = forbiddenSubstrings
        self.maxLength = maxLength
        self.rubricTags = rubricTags
    }
}

/// Quantified quality of one completion against its expected continuation.
///
/// Metrics are cheap, deterministic string comparisons, so they run on any
/// engine (mock or real) with no extra dependencies. Exact match is deliberately
/// just one metric among many — it is never the headline.
public struct EvalMetrics: Codable {
    /// True when `actual` exactly equals `expected`.
    public var exactMatch: Bool
    /// Number of leading characters of `expected` that `actual` matches.
    public var prefixMatch: Int
    /// Whitespace-token F1 (bag-of-words overlap) between `actual` and `expected`.
    public var tokenF1: Double
    /// `actual` length / `expected` length; guarded against a zero denominator.
    public var lengthRatio: Double
    /// Structurally valid: no forbidden output, no over-generation, and a
    /// plausible continuation (or a correct abstain).
    public var valid: Bool
    /// True when `actual` exactly equals `expected` or any accepted alternative.
    public var matchedAlternative: Bool
    /// Number of forbidden substrings present in the completed output.
    public var forbiddenCount: Int
    /// True when any forbidden substring is present.
    public var hasForbiddenOutput: Bool
    /// True when `maxLength` is set and `actual` exceeds it.
    public var isOverlong: Bool
    /// Normalized edit similarity (1 - Levenshtein/maxLen) against the best
    /// expected/alternative, in `0...1`.
    public var editSimilarity: Double

    public init(
        exactMatch: Bool,
        prefixMatch: Int,
        tokenF1: Double,
        lengthRatio: Double,
        valid: Bool,
        matchedAlternative: Bool,
        forbiddenCount: Int,
        hasForbiddenOutput: Bool,
        isOverlong: Bool,
        editSimilarity: Double
    ) {
        self.exactMatch = exactMatch
        self.prefixMatch = prefixMatch
        self.tokenF1 = tokenF1
        self.lengthRatio = lengthRatio
        self.valid = valid
        self.matchedAlternative = matchedAlternative
        self.forbiddenCount = forbiddenCount
        self.hasForbiddenOutput = hasForbiddenOutput
        self.isOverlong = isOverlong
        self.editSimilarity = editSimilarity
    }

    /// Compute the metrics for one completion, given its accepted alternatives,
    /// forbidden substrings, and length cap.
    public static func compute(
        actual: String,
        expected: String,
        acceptedAlternatives: [String] = [],
        forbiddenSubstrings: [String] = [],
        maxLength: Int? = nil
    ) -> EvalMetrics {
        let forbiddenCount = forbiddenSubstrings.reduce(0) { count, token in
            count + (token.isEmpty ? 0 : (actual.contains(token) ? 1 : 0))
        }
        let hasForbidden = forbiddenCount > 0

        let alternatives = [expected] + acceptedAlternatives
        // A match requires that something was actually produced (an abstain with
        // nothing to show is not a "matched alternative").
        let matched = !actual.isEmpty && alternatives.contains { $0 == actual }
        let similarity = bestEditSimilarity(actual: actual, references: alternatives)

        let isOverlong = maxLength.map { actual.count > $0 } ?? false

        // An empty expected marks an abstain case: valid only if the model also
        // produced nothing (or an allowed short alternative, covered by `matched`).
        // A non-empty expected requires a plausible, non-forbidden continuation.
        let valid = !hasForbidden
            && !isOverlong
            && (actual.isEmpty ? expected.isEmpty : (matched || similarity >= 0.5))

        return EvalMetrics(
            exactMatch: actual == expected,
            prefixMatch: commonPrefixLength(actual, expected),
            tokenF1: tokenF1(actual, expected),
            lengthRatio: lengthRatio(actual, expected),
            valid: valid,
            matchedAlternative: matched,
            forbiddenCount: forbiddenCount,
            hasForbiddenOutput: hasForbidden,
            isOverlong: isOverlong,
            editSimilarity: similarity
        )
    }

    /// Best normalized edit similarity between `actual` and any reference.
    static func bestEditSimilarity(actual: String, references: [String]) -> Double {
        guard !references.isEmpty else { return actual.isEmpty ? 1 : 0 }
        // If every reference is empty, only an empty actual can be similar.
        if references.allSatisfy({ $0.isEmpty }) {
            return actual.isEmpty ? 1 : 0
        }
        var best = 0.0
        for reference in references where !reference.isEmpty {
            best = max(best, editSimilarity(actual: actual, reference: reference))
        }
        return best
    }

    /// Normalized edit similarity in `0...1`.
    static func editSimilarity(actual: String, reference: String) -> Double {
        let distance = levenshtein(Array(actual), Array(reference))
        let maxLen = max(actual.count, reference.count)
        return maxLen == 0 ? 1.0 : 1.0 - Double(distance) / Double(maxLen)
    }

    /// Classic Levenshtein edit distance over two character arrays.
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, aChar) in a.enumerated() {
            var current = [i + 1]
            for (j, bChar) in b.enumerated() {
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let substitution = previous[j] + (aChar == bChar ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Length of the longest common character prefix between two strings.
    static func commonPrefixLength(_ actual: String, _ expected: String) -> Int {
        let a = Array(actual)
        let e = Array(expected)
        var count = 0
        for i in 0..<min(a.count, e.count) {
            if a[i] == e[i] { count += 1 } else { break }
        }
        return count
    }

    /// Bag-of-words F1: overlap counts duplicate tokens, so ordering is ignored
    /// but repeated tokens matter.
    static func tokenF1(_ actual: String, _ expected: String) -> Double {
        let aTokens = actual.split(whereSeparator: \.isWhitespace).map(String.init)
        let eTokens = expected.split(whereSeparator: \.isWhitespace).map(String.init)

        guard !aTokens.isEmpty || !eTokens.isEmpty else { return 1.0 }
        guard !aTokens.isEmpty, !eTokens.isEmpty else { return 0.0 }

        var remaining: [String: Int] = [:]
        for token in eTokens { remaining[token, default: 0] += 1 }

        var overlap = 0
        for token in aTokens {
            if let count = remaining[token], count > 0 {
                overlap += 1
                remaining[token] = count - 1
            }
        }

        let precision = Double(overlap) / Double(aTokens.count)
        let recall = Double(overlap) / Double(eTokens.count)
        let sum = precision + recall
        guard sum > 0 else { return 0.0 }
        return 2 * precision * recall / sum
    }

    /// Actual/expected character-length ratio, guarded against a zero
    /// `expected`. An empty expected scores 1.0 only when actual is also empty.
    static func lengthRatio(_ actual: String, _ expected: String) -> Double {
        let expectedLength = expected.count
        guard expectedLength > 0 else { return actual.isEmpty ? 1.0 : 0.0 }
        return Double(actual.count) / Double(expectedLength)
    }
}

/// One evaluation run: the case, the raw engine output, the sanitized actual,
/// its metrics, the explicit outcome, and timing.
public struct EvalResult: Codable {
    public var `case`: EvalCase
    /// The sanitized output that would be shown/inserted.
    public var actual: String
    /// The engine's raw output before canonical sanitization (for diagnostics
    /// and leak measurement).
    public var rawOutput: String
    public var metrics: EvalMetrics
    public var outcome: EvalOutcome
    /// End-to-end completion latency, excluding model load time.
    public var duration: TimeInterval
    /// Wall-clock time from request start to the first streamed token.
    public var timeToFirstToken: TimeInterval
    /// Number of generated tokens emitted by the engine.
    public var tokenCount: Int
    /// Generated tokens per second over the generation window.
    public var tokensPerSecond: Double

    public init(
        `case`: EvalCase,
        actual: String,
        rawOutput: String,
        metrics: EvalMetrics,
        outcome: EvalOutcome,
        duration: TimeInterval = 0,
        timeToFirstToken: TimeInterval = 0,
        tokenCount: Int = 0,
        tokensPerSecond: Double = 0
    ) {
        self.`case` = `case`
        self.actual = actual
        self.rawOutput = rawOutput
        self.metrics = metrics
        self.outcome = outcome
        self.duration = duration
        self.timeToFirstToken = timeToFirstToken
        self.tokenCount = tokenCount
        self.tokensPerSecond = tokensPerSecond
    }
}

/// Thresholds that turn a scoreboard into a release gate. A command that always
/// exits zero regardless of these is not a gate.
public struct EvalGates: Codable, Equatable {
    /// Maximum tolerated failed (outcome == .failure) cases.
    public var maxFailures: Int
    /// Maximum tolerated forbidden-output cases.
    public var maxForbiddenOutputs: Int
    /// Minimum fraction of cases that are structurally valid (0...1).
    public var minValidRate: Double

    public init(maxFailures: Int = 0, maxForbiddenOutputs: Int = 0, minValidRate: Double = 0.90) {
        self.maxFailures = maxFailures
        self.maxForbiddenOutputs = maxForbiddenOutputs
        self.minValidRate = minValidRate
    }
}

/// Aggregate metrics across a whole run, with a human-readable scoreboard and a
/// JSON machine-readable form.
public struct EvalSummary {
    public var caseCount: Int
    public var exactMatchCount: Int
    public var matchedAlternativeCount: Int
    public var validCount: Int
    public var forbiddenOutputCount: Int
    public var overlongCount: Int
    public var noSuggestionCount: Int
    public var failureCount: Int

    public var averagePrefixMatch: Double
    public var averageTokenF1: Double
    public var averageLengthRatio: Double
    public var averageEditSimilarity: Double
    public var averageLatency: TimeInterval
    public var medianLatency: TimeInterval
    public var averageTTFT: TimeInterval
    public var medianTTFT: TimeInterval
    public var averageThroughput: Double
    public var medianThroughput: Double
    public var averageTokenCount: Double

    public init(results: [EvalResult]) {
        caseCount = results.count
        exactMatchCount = results.filter { $0.metrics.exactMatch }.count
        matchedAlternativeCount = results.filter { $0.metrics.matchedAlternative }.count
        validCount = results.filter { $0.metrics.valid }.count
        forbiddenOutputCount = results.filter { $0.metrics.hasForbiddenOutput }.count
        overlongCount = results.filter { $0.metrics.isOverlong }.count
        noSuggestionCount = results.filter { $0.outcome == .noSuggestion }.count
        failureCount = results.filter { if case .failure = $0.outcome { return true } else { return false } }.count

        guard caseCount > 0 else {
            averagePrefixMatch = 0
            averageTokenF1 = 0
            averageLengthRatio = 0
            averageEditSimilarity = 0
            averageLatency = 0
            medianLatency = 0
            averageTTFT = 0
            medianTTFT = 0
            averageThroughput = 0
            medianThroughput = 0
            averageTokenCount = 0
            return
        }

        averagePrefixMatch = results.reduce(0) { $0 + Double($1.metrics.prefixMatch) } / Double(caseCount)
        averageTokenF1 = results.reduce(0) { $0 + $1.metrics.tokenF1 } / Double(caseCount)
        averageLengthRatio = results.reduce(0) { $0 + $1.metrics.lengthRatio } / Double(caseCount)
        averageEditSimilarity = results.reduce(0) { $0 + $1.metrics.editSimilarity } / Double(caseCount)

        let durations = results.map(\.duration).sorted()
        averageLatency = durations.reduce(0, +) / Double(caseCount)
        medianLatency = Self.median(durations)

        let ttfts = results.map(\.timeToFirstToken).sorted()
        averageTTFT = ttfts.reduce(0, +) / Double(caseCount)
        medianTTFT = Self.median(ttfts)

        let throughputs = results.map(\.tokensPerSecond)
        averageThroughput = throughputs.reduce(0, +) / Double(caseCount)
        medianThroughput = Self.median(throughputs)
        averageTokenCount = Double(results.map(\.tokenCount).reduce(0, +)) / Double(caseCount)
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Rate helpers for a gate check.
    public var validRate: Double { caseCount > 0 ? Double(validCount) / Double(caseCount) : 0 }
    public var forbiddenOutputRate: Double { caseCount > 0 ? Double(forbiddenOutputCount) / Double(caseCount) : 0 }
    public var overlongRate: Double { caseCount > 0 ? Double(overlongCount) / Double(caseCount) : 0 }

    /// Whether a run passes the provided gates.
    public func passes(_ gates: EvalGates) -> Bool {
        failureCount <= gates.maxFailures
            && forbiddenOutputCount <= gates.maxForbiddenOutputs
            && validRate >= gates.minValidRate
    }

    /// A structured machine-readable record of a run (summary + per-case rows).
    public struct JSONRecord: Codable {
        public var summary: SummaryRecord
        public var cases: [CaseRecord]
    }

    public struct SummaryRecord: Codable {
        public var caseCount: Int
        public var validRate: Double
        public var matchedAlternativeRate: Double
        public var exactMatchRate: Double
        public var forbiddenOutputCount: Int
        public var forbiddenOutputRate: Double
        public var overlongRate: Double
        public var noSuggestionCount: Int
        public var failureCount: Int
        public var avgEditSimilarity: Double
        public var avgTokenF1: Double
        public var avgLatency: Double
        public var medianLatency: Double
        public var avgTTFT: Double
        public var medianTTFT: Double
        public var avgThroughput: Double
        public var medianThroughput: Double
        public var avgTokenCount: Double
    }

    public struct CaseRecord: Codable {
        public var id: String
        public var rubricTags: [String]
        public var outcome: String
        public var actual: String
        public var expected: String
        public var exactMatch: Bool
        public var matchedAlternative: Bool
        public var valid: Bool
        public var forbiddenCount: Int
        public var isOverlong: Bool
        public var editSimilarity: Double
        public var tokenF1: Double
        public var duration: Double
        public var ttft: Double
        public var tokenCount: Int
        public var tokensPerSecond: Double
    }

    /// Build a machine-readable record for the whole run.
    public func jsonRecord(results: [EvalResult]) -> JSONRecord {
        JSONRecord(
            summary: SummaryRecord(
                caseCount: caseCount,
                validRate: validRate,
                matchedAlternativeRate: caseCount > 0 ? Double(matchedAlternativeCount) / Double(caseCount) : 0,
                exactMatchRate: caseCount > 0 ? Double(exactMatchCount) / Double(caseCount) : 0,
                forbiddenOutputCount: forbiddenOutputCount,
                forbiddenOutputRate: forbiddenOutputRate,
                overlongRate: overlongRate,
                noSuggestionCount: noSuggestionCount,
                failureCount: failureCount,
                avgEditSimilarity: averageEditSimilarity,
                avgTokenF1: averageTokenF1,
                avgLatency: averageLatency,
                medianLatency: medianLatency,
                avgTTFT: averageTTFT,
                medianTTFT: medianTTFT,
                avgThroughput: averageThroughput,
                medianThroughput: medianThroughput,
                avgTokenCount: averageTokenCount
            ),
            cases: results.map { result in
                CaseRecord(
                    id: result.`case`.id,
                    rubricTags: result.`case`.rubricTags,
                    outcome: outcomeString(result.outcome),
                    actual: result.actual,
                    expected: result.`case`.expected,
                    exactMatch: result.metrics.exactMatch,
                    matchedAlternative: result.metrics.matchedAlternative,
                    valid: result.metrics.valid,
                    forbiddenCount: result.metrics.forbiddenCount,
                    isOverlong: result.metrics.isOverlong,
                    editSimilarity: result.metrics.editSimilarity,
                    tokenF1: result.metrics.tokenF1,
                    duration: result.duration,
                    ttft: result.timeToFirstToken,
                    tokenCount: result.tokenCount,
                    tokensPerSecond: result.tokensPerSecond
                )
            }
        )
    }

    /// Encode the JSON record, pretty-printed and key-sorted for stable diffs.
    public func jsonEncoded(results: [EvalResult]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(jsonRecord(results: results))
    }

    /// A formatted human-readable scoreboard. Exact match is reported but is
    /// never the headline — validity, forbidden output, and over-generation are.
    public var scoreboardDescription: String {
        var lines: [String] = []
        lines.append("COTYPE EVAL SCOREBOARD")
        lines.append(String(repeating: "=", count: 32))
        lines.append(field("cases", "\(caseCount)"))
        lines.append(field("valid", "\(validCount) (\(String(format: "%.1f", validRate * 100))%)"))
        lines.append(field("matched alt", "\(matchedAlternativeCount) (\(String(format: "%.1f", matchedAlternativeCountRate * 100))%)"))
        lines.append(field("exact match", "\(exactMatchCount) (\(String(format: "%.1f", exactMatchRate * 100))%)"))
        lines.append(field("forbidden", "\(forbiddenOutputCount) (\(String(format: "%.1f", forbiddenOutputRate * 100))%)"))
        lines.append(field("overlong", "\(overlongCount) (\(String(format: "%.1f", overlongRate * 100))%)"))
        lines.append(field("no suggestion", "\(noSuggestionCount)"))
        lines.append(field("failures", "\(failureCount)"))
        lines.append(String(repeating: "-", count: 32))
        lines.append(field("avg edit sim", String(format: "%.4f", averageEditSimilarity)))
        lines.append(field("avg token F1", String(format: "%.4f", averageTokenF1)))
        lines.append(field("avg length ratio", String(format: "%.4f", averageLengthRatio)))
        lines.append(String(repeating: "-", count: 32))
        lines.append(field("avg latency", String(format: "%.3f s", averageLatency)))
        lines.append(field("median latency", String(format: "%.3f s", medianLatency)))
        lines.append(field("avg TTFT", String(format: "%.3f s", averageTTFT)))
        lines.append(field("median TTFT", String(format: "%.3f s", medianTTFT)))
        lines.append(field("median throughput", String(format: "%.1f tok/s", medianThroughput)))
        lines.append(field("avg throughput", String(format: "%.1f tok/s", averageThroughput)))
        lines.append(field("avg tokens", String(format: "%.1f", averageTokenCount)))
        return lines.joined(separator: "\n")
    }

    private var matchedAlternativeCountRate: Double {
        caseCount > 0 ? Double(matchedAlternativeCount) / Double(caseCount) : 0
    }
    private var exactMatchRate: Double {
        caseCount > 0 ? Double(exactMatchCount) / Double(caseCount) : 0
    }

    /// Right-align the value column at a fixed width for a tidy scoreboard.
    private func field(_ label: String, _ value: String) -> String {
        let paddedLabel = label + ":"
        let width = 24
        let pad = max(1, width - paddedLabel.count)
        return paddedLabel + String(repeating: " ", count: pad) + value
    }

    private func outcomeString(_ outcome: EvalOutcome) -> String {
        switch outcome {
        case .suggestion: return "suggestion"
        case .noSuggestion: return "noSuggestion"
        case .failure(let message): return "failure: \(message)"
        }
    }
}
