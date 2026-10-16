import XCTest
@testable import CotypeEval
import CotypeCore

final class EvalMetricsTests: XCTestCase {

    // MARK: exactMatch (secondary, never headline)

    func testExactMatchTrue() {
        let metrics = EvalMetrics.compute(actual: "a + b", expected: "a + b")
        XCTAssertTrue(metrics.exactMatch)
    }

    func testExactMatchFalse() {
        let metrics = EvalMetrics.compute(actual: "a + b", expected: "a - b")
        XCTAssertFalse(metrics.exactMatch)
    }

    func testExactMatchCaseSensitive() {
        let metrics = EvalMetrics.compute(actual: "Paris", expected: "paris")
        XCTAssertFalse(metrics.exactMatch)
    }

    // MARK: prefixMatch

    func testPrefixMatchPartial() {
        let metrics = EvalMetrics.compute(actual: "a + b + c", expected: "a + b")
        XCTAssertEqual(metrics.prefixMatch, 5)
    }

    func testPrefixMatchNone() {
        let metrics = EvalMetrics.compute(actual: "hello", expected: "world")
        XCTAssertEqual(metrics.prefixMatch, 0)
    }

    // MARK: tokenF1

    func testTokenF1Identical() {
        let f1 = EvalMetrics.compute(actual: "a b c", expected: "a b c").tokenF1
        XCTAssertEqual(f1, 1.0, accuracy: 1e-9)
    }

    func testTokenF1Disjoint() {
        let f1 = EvalMetrics.compute(actual: "a b", expected: "x y").tokenF1
        XCTAssertEqual(f1, 0.0, accuracy: 1e-9)
    }

    func testTokenF1PartialOverlap() {
        let f1 = EvalMetrics.compute(actual: "a b", expected: "a c").tokenF1
        XCTAssertEqual(f1, 0.5, accuracy: 1e-9)
    }

    // MARK: accepted alternatives

    func testMatchedAlternativeWhenEqualToAlternative() {
        let metrics = EvalMetrics.compute(actual: "friends", expected: "world", acceptedAlternatives: ["friends", "mates"])
        XCTAssertTrue(metrics.matchedAlternative)
        XCTAssertFalse(metrics.exactMatch)
        XCTAssertTrue(metrics.valid) // non-forbidden, on-target
    }

    func testNotMatchedWhenOffTarget() {
        let metrics = EvalMetrics.compute(actual: "banana", expected: "world", acceptedAlternatives: ["friends"])
        XCTAssertFalse(metrics.matchedAlternative)
        XCTAssertFalse(metrics.valid) // similarity to "friends"/"world" < 0.5
    }

    // MARK: forbidden-output

    func testForbiddenCountDetectsSubstrings() {
        let metrics = EvalMetrics.compute(
            actual: "still<|turn>stuff",
            expected: "still",
            forbiddenSubstrings: ["<|turn>", "<|channel"]
        )
        XCTAssertEqual(metrics.forbiddenCount, 1)
        XCTAssertTrue(metrics.hasForbiddenOutput)
        XCTAssertFalse(metrics.valid)
    }

    func testForbiddenCountZeroWhenClean() {
        let metrics = EvalMetrics.compute(actual: "dog", expected: "dog", forbiddenSubstrings: ["<|turn>"])
        XCTAssertEqual(metrics.forbiddenCount, 0)
        XCTAssertFalse(metrics.hasForbiddenOutput)
    }

    // MARK: over-generation

    func testIsOverlongWhenExceedingCap() {
        let metrics = EvalMetrics.compute(actual: "a very long continuation", expected: "short", maxLength: 10)
        XCTAssertTrue(metrics.isOverlong)
        XCTAssertFalse(metrics.valid)
    }

    func testWithinMaxLengthIsNotOverlong() {
        let metrics = EvalMetrics.compute(actual: "a + b", expected: "a + b", maxLength: 10)
        XCTAssertFalse(metrics.isOverlong)
        XCTAssertTrue(metrics.valid)
    }

    // MARK: edit similarity

    func testEditSimilarityExactIsOne() {
        let m = EvalMetrics.compute(actual: "dog", expected: "dog")
        XCTAssertEqual(m.editSimilarity, 1.0, accuracy: 1e-9)
    }

    func testEditSimilarityPartial() {
        let m = EvalMetrics.compute(actual: "dog", expected: "dot")
        XCTAssertEqual(m.editSimilarity, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testEditSimilarityZeroForDisjoint() {
        let m = EvalMetrics.compute(actual: "abc", expected: "xyz")
        XCTAssertEqual(m.editSimilarity, 0.0, accuracy: 1e-9)
    }

    // MARK: validity incl. abstain

    func testAbstainCaseValidOnlyWhenEmpty() {
        // expected is empty => abstain case; only an empty actual is valid.
        let valid = EvalMetrics.compute(actual: "", expected: "")
        XCTAssertTrue(valid.valid)
        let over = EvalMetrics.compute(actual: "unwanted", expected: "")
        XCTAssertFalse(over.valid)
    }

    func testNonAbstainEmptyOutputIsInvalid() {
        let metrics = EvalMetrics.compute(actual: "", expected: "answer")
        XCTAssertFalse(metrics.valid)
    }

    // MARK: summary aggregation

    func testSummaryAggregatesNewMetrics() {
        let abort = EvalCase(id: "a", prefix: "", expected: "")
        let prose = EvalCase(id: "p", prefix: "", expected: "dog", acceptedAlternatives: ["dog"])

        let results = [
            EvalResult(
                case: abort,
                actual: "",
                rawOutput: "",
                metrics: EvalMetrics.compute(actual: "", expected: ""),
                outcome: .noSuggestion,
                duration: 0.2,
                timeToFirstToken: 0.1,
                tokenCount: 0,
                tokensPerSecond: 0
            ),
            EvalResult(
                case: prose,
                actual: "dog",
                rawOutput: "dog",
                metrics: EvalMetrics.compute(actual: "dog", expected: "dog", acceptedAlternatives: ["dog"]),
                outcome: .suggestion,
                duration: 0.4,
                timeToFirstToken: 0.2,
                tokenCount: 4,
                tokensPerSecond: 10
            ),
        ]

        let summary = EvalSummary(results: results)
        XCTAssertEqual(summary.caseCount, 2)
        XCTAssertEqual(summary.validCount, 2)
        XCTAssertEqual(summary.matchedAlternativeCount, 1)
        XCTAssertEqual(summary.forbiddenOutputCount, 0)
        XCTAssertEqual(summary.noSuggestionCount, 1)
        XCTAssertEqual(summary.averageLatency, 0.3, accuracy: 1e-9)
        XCTAssertEqual(summary.medianLatency, 0.3, accuracy: 1e-9)
        XCTAssertEqual(summary.averageTTFT, 0.15, accuracy: 1e-9)
        XCTAssertEqual(summary.averageThroughput, 5.0, accuracy: 1e-9)
        XCTAssertEqual(summary.medianThroughput, 5.0, accuracy: 1e-9)
        XCTAssertEqual(summary.validRate, 1.0, accuracy: 1e-9)
    }

    func testSummaryPassesGates() {
        let fail = EvalResult(
            case: EvalCase(id: "f", prefix: "", expected: ""),
            actual: "",
            rawOutput: "",
            metrics: EvalMetrics.compute(actual: "", expected: ""),
            outcome: .failure("boom")
        )
        let summary = EvalSummary(results: [fail])
        XCTAssertFalse(summary.passes(EvalGates(maxFailures: 0)))
        XCTAssertTrue(summary.passes(EvalGates(maxFailures: 1)))
    }

    func testSummaryJSONEncodesWithPerCaseRows() throws {
        let results = [
            EvalResult(
                case: EvalCase(id: "x", prefix: "", expected: "a + b"),
                actual: "a + b",
                rawOutput: "a + b",
                metrics: EvalMetrics.compute(actual: "a + b", expected: "a + b"),
                outcome: .suggestion,
                duration: 0.1,
                timeToFirstToken: 0.05,
                tokenCount: 3,
                tokensPerSecond: 30
            )
        ]
        let summary = EvalSummary(results: results)
        let data = try summary.jsonEncoded(results: results)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"id\" : \"x\""))
        XCTAssertTrue(json.contains("\"validRate\""))
        XCTAssertTrue(json.contains("\"outcome\" : \"suggestion\""))
    }

    // MARK: runner integration

    func testRunnerReturnsOneResultPerCaseAgainstMock() async {
        let engine = MockInferenceEngine(response: "x", wordDelayNanoseconds: 0)
        let results = await EvalRunner.run(cases: SeededEvalSet.cases, engine: engine)
        XCTAssertEqual(results.count, SeededEvalSet.cases.count)
        for result in results {
            XCTAssertFalse(result.`case`.id.isEmpty)
        }
    }

    func testSeededSetIsNonEmptyAndDeterministic() {
        XCTAssertFalse(SeededEvalSet.cases.isEmpty)
        let ids = SeededEvalSet.cases.map(\.id)
        XCTAssertEqual(ids, SeededEvalSet.cases.map(\.id))
        // The set now carries the fields the regression baseline needs.
        let withAlternatives = SeededEvalSet.cases.filter { !$0.acceptedAlternatives.isEmpty }
        XCTAssertFalse(withAlternatives.isEmpty)
        let withForbidden = SeededEvalSet.cases.filter { !$0.forbiddenSubstrings.isEmpty }
        XCTAssertEqual(withForbidden.count, SeededEvalSet.cases.count)
        // Abstain cases carry an empty expected.
        XCTAssertTrue(SeededEvalSet.cases.contains { $0.expected.isEmpty })
    }

    // MARK: scoreboard is no longer exact-match-headline

    func testScoreboardLeadsWithValidityNotExactMatch() {
        let summary = EvalSummary(results: [])
        let board = summary.scoreboardDescription
        // Validity is listed before exact match, so exact match is not the headline.
        let validRange = board.range(of: "valid")!
        let exactRange = board.range(of: "exact match")!
        XCTAssertLessThan(validRange.lowerBound, exactRange.lowerBound)
    }
}
