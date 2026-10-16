import XCTest
@testable import CotypeEval
import CotypeCore

final class PerformanceGatesTests: XCTestCase {

    func testPassesWhenThroughputAndColdLoadMeetThresholds() {
        let gates = PerformanceGates.modelRelease
        XCTAssertTrue(gates.passes(tokensPerSecond: 45, coldLoadSeconds: 8.0))
        XCTAssertTrue(gates.passes(tokensPerSecond: 20, coldLoadSeconds: 15.0), "inclusive bounds pass")
    }

    func testFailsWhenThroughputTooLow() {
        let gates = PerformanceGates.modelRelease
        XCTAssertFalse(gates.passes(tokensPerSecond: 19.9, coldLoadSeconds: 8.0))
        XCTAssertFalse(gates.passes(tokensPerSecond: 0, coldLoadSeconds: 8.0))
    }

    func testFailsWhenColdLoadTooSlow() {
        let gates = PerformanceGates.modelRelease
        XCTAssertFalse(gates.passes(tokensPerSecond: 45, coldLoadSeconds: 15.5))
    }

    func testRequiredGateWithUnavailableMetricFails() {
        // A required threshold with a nil (unmeasured) metric must FAIL — we
        // never report an unavailable measurement as passing.
        let gates = PerformanceGates.modelRelease
        XCTAssertFalse(gates.passes(tokensPerSecond: nil, coldLoadSeconds: nil),
                       "an unavailable required metric must fail the gate")
        // Even if only one is unavailable.
        XCTAssertFalse(gates.passes(tokensPerSecond: 45, coldLoadSeconds: nil))
        XCTAssertFalse(gates.passes(tokensPerSecond: nil, coldLoadSeconds: 8.0))
    }

    func testNoRequiredGatesAlwaysPasses() {
        let gates = PerformanceGates()
        XCTAssertTrue(gates.passes(tokensPerSecond: nil, coldLoadSeconds: nil))
        XCTAssertTrue(gates.passes(tokensPerSecond: 0, coldLoadSeconds: 0))
    }

    func testRequirementsDescription() {
        XCTAssertEqual(PerformanceGates.modelRelease.requirementsDescription, "tokens/s >= 20, cold load <= 15s")
        XCTAssertEqual(PerformanceGates().requirementsDescription, "none")
    }
}

final class PerformanceProvenanceTests: XCTestCase {

    func testProvenanceRoundTripsThroughCodable() throws {
        let provenance = MachineProvenance(
            gitCommit: "abc123",
            osName: "macOS",
            osVersion: "15.0.0",
            machineArch: "arm64",
            physicalRAMBytes: 34_359_738_368,
            cpuBrand: "Apple M3",
            cpuCount: 12,
            llamaBuild: "b10665",
            model: ModelProvenance(
                path: "/tmp/model.gguf",
                file: "model.gguf",
                repo: "unsloth/gemma-4-E2B-it-GGUF",
                revision: "0314792d7f1f7e229411f620751375812bb9faf2",
                sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8"
            ),
            runTimestamp: Date(timeIntervalSinceReferenceDate: 750_000_000)
        )
        let data = try JSONEncoder().encode(provenance)
        let decoded = try JSONDecoder().decode(MachineProvenance.self, from: data)
        XCTAssertEqual(decoded, provenance)
    }

    func testReportEncodesProvenanceConfigPerformanceAndGates() throws {
        let result = EvalResult(
            case: EvalCase(id: "x", prefix: "", expected: "dog"),
            actual: "dog",
            rawOutput: "dog",
            metrics: EvalMetrics.compute(actual: "dog", expected: "dog"),
            outcome: .suggestion,
            duration: 0.4,
            timeToFirstToken: 0.2,
            tokenCount: 4,
            tokensPerSecond: 10
        )
        let summary = EvalSummary(results: [result])
        let report = EvalRunReport(
            provenance: MachineProvenance(gitCommit: "abc123", osName: "macOS", osVersion: "15.0.0", machineArch: "arm64"),
            config: EvalRunConfig(maxTokens: 32, caseSetCount: 1),
            performance: PerformanceSummary(averageTokensPerSecond: 10, coldLoadSeconds: 5.0),
            gates: .modelRelease,
            gatesPassed: false,
            record: summary.jsonRecord(results: [result])
        )
        let data = try report.jsonEncoded()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"gitCommit\""))
        XCTAssertTrue(json.contains("\"gatesPassed\" : false"))
        XCTAssertTrue(json.contains("\"averageTokensPerSecond\""))
        XCTAssertTrue(json.contains("\"validRate\""))
        XCTAssertTrue(json.contains("\"caseSetCount\""))
    }

    func testCapuresNonNullHostFields() {
        let provenance = MachineProvenance.capture(gitCommit: "abc", llamaBuild: "b10665")
        XCTAssertEqual(provenance.gitCommit, "abc")
        XCTAssertEqual(provenance.llamaBuild, "b10665")
        XCTAssertFalse(provenance.osName.isEmpty)
        XCTAssertFalse(provenance.machineArch.isEmpty)
        // RAM / CPU are present on the machine running the tests.
        XCTAssertNotNil(provenance.physicalRAMBytes)
        XCTAssertNotNil(provenance.cpuCount)
    }
}
