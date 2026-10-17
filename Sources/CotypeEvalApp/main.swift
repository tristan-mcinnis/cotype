import Foundation
import CotypeEval
import CotypeCore
import CotypeMacOS

// cotype-eval: run the seeded completion-eval set against an engine and report a
// release gate with a threshold-based exit code.
//
//   cotype-eval                        -> MockInferenceEngine (deterministic)
//   cotype-eval --engine openai        -> OpenAICompatibleEngine from env vars
//   cotype-eval --engine llama         -> LlamaCppEngine (local GGUF, Metal)
//   cotype-eval --engine daemon        -> the app's production engine: Local
//                                         Models registry -> warm llama-server
//
// Flags:
//   --model <path>       GGUF path (llama only; defaults to the Cotype Models dir)
//   --max-tokens <n>     cap generated tokens (llama only, default 128)
//   --limit <n>          run only the first n cases (smoke testing)
//   --json               also emit machine-readable results (stdout)
//   --min-valid-rate <x> gate: minimum valid fraction (default 0.90)
//   --max-forbidden <n>  gate: max forbidden-output cases (default 0)
//   --max-failures <n>   gate: max pipeline failures (default 0)
//
// Engine env vars (openai only): OPENAI_BASE_URL (default
// http://localhost:8080/v1), OPENAI_MODEL (default "local-model"),
// OPENAI_API_KEY (optional).

func envText(_ key: String, default defaultValue: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? defaultValue
}

func flagValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func intFlag(_ name: String, default defaultValue: Int) -> Int {
    guard let text = flagValue(name), let value = Int(text) else { return defaultValue }
    return value
}

func doubleFlag(_ name: String, default defaultValue: Double) -> Double {
    guard let text = flagValue(name), let value = Double(text) else { return defaultValue }
    return value
}

func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func writeErr(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

/// Shell out and capture stdout (used for git provenance). Returns nil on any
/// failure; provenance is never fabricated.
func shellOutput(_ command: String...) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    } catch {
        return nil
    }
}

/// Peak resident memory (bytes) for the current process, from getrusage.
func peakResidentMemoryBytes() -> Double? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
    return Double(usage.ru_maxrss)
}

func seconds(_ duration: Duration) -> Double {
    let c = duration.components
    return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
}

let engineName = flagValue("--engine") ?? "mock"
let modelPath = flagValue("--model") ?? LlamaCppEngine.defaultModelPath()
let maxTokens = Int32(intFlag("--max-tokens", default: 128))
let limit = intFlag("--limit", default: 0)
// The author's custom writing-style note for the instruction lane. Empty means
// none; the fixed continuation directive is added by the app-equivalent
// composition. This is not the legacy `Input:/Output:` boilerplate.
let systemPrompt = envText("COTYPE_EVAL_SYSTEM_PROMPT", default: "")
// Prompt style under test (default: the app's default). A/B only; the gate
// command does not set it.
let promptStyle = PromptStyle(rawValue: envText("COTYPE_EVAL_PROMPT_STYLE", default: PromptStyle.default.rawValue)) ?? .default
let evalLength = SuggestionLength(rawValue: envText("COTYPE_EVAL_LENGTH", default: SuggestionLength.default.rawValue)) ?? .default
// Learned-example A/B input for the instruction lane. Empty (the default) keeps
// the measured request unchanged.
let evalExamples = envText("COTYPE_EVAL_EXAMPLES", default: "")

let engine: InferenceEngine
let engineLabel: String
let configDescription: [String: String]
var modelProvenance = ModelProvenance(
    path: modelPath,
    file: modelPath.map { ($0 as NSString).lastPathComponent },
    repo: flagValue("--model-repo"),
    revision: flagValue("--model-revision"),
    sha256: flagValue("--model-sha") ?? (modelPath.flatMap { p in
        FileManager.default.fileExists(atPath: p) ? (try? sha256OfFile(at: URL(fileURLWithPath: p))) : nil
    })
)
var coldLoadSeconds: Double?
switch engineName {
case "openai":
    let baseURLString = envText("OPENAI_BASE_URL", default: "http://localhost:8080/v1")
    let model = envText("OPENAI_MODEL", default: "local-model")
    guard let baseURL = URL(string: baseURLString) else {
        writeErr("Invalid OPENAI_BASE_URL: \(baseURLString)")
        exit(2)
    }
    let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    engine = OpenAICompatibleEngine(baseURL: baseURL, model: model, apiKey: apiKey)
    engineLabel = "openai (\(model) @ \(baseURLString))"
    configDescription = ["engine": "openai", "model": model, "base_url": baseURLString]
case "llama":
    guard let path = modelPath else {
        writeErr("No model found. Pass --model <path> or place a .gguf in " +
                 "~/Library/Application Support/Cotype/Models/")
        exit(2)
    }
    let loadStart = ContinuousClock.now
    do {
        engine = try LlamaCppEngine(path: path, maxTokens: maxTokens, temperature: 0, quietLogs: true)
    } catch {
        writeErr("Failed to load model at \(path): \(error)")
        exit(2)
    }
    coldLoadSeconds = seconds(ContinuousClock.now - loadStart)
    modelProvenance = ModelProvenance(
        path: path,
        file: (path as NSString).lastPathComponent,
        repo: flagValue("--model-repo"),
        revision: flagValue("--model-revision"),
        sha256: flagValue("--model-sha") ?? (try? sha256OfFile(at: URL(fileURLWithPath: path)))
    )
    engineLabel = "llama.cpp (\((path as NSString).lastPathComponent))"
    configDescription = ["engine": "llama.cpp", "model": (path as NSString).lastPathComponent]
case "daemon":
    // Exactly what the menu app streams from: registry lookup on the Local
    // Models control plane, then the advertised warm endpoint.
    let alias = flagValue("--daemon-model") ?? DaemonRoutedEngine.defaultModel
    engine = LocalModelsCompletionEngine(modelAlias: alias, maxTokens: Int(maxTokens), temperature: 0)
    engineLabel = "local-models daemon (\(alias))"
    configDescription = ["engine": "daemon", "model": alias]
default:
    engine = MockInferenceEngine(response: "your own completion", wordDelayNanoseconds: 0)
    engineLabel = "mock (deterministic)"
    configDescription = ["engine": "mock"]
}

let gates = EvalGates(
    maxFailures: intFlag("--max-failures", default: 0),
    maxForbiddenOutputs: intFlag("--max-forbidden", default: 0),
    minValidRate: doubleFlag("--min-valid-rate", default: 0.90)
)

let adherenceSet = hasFlag("--adherence-set")
var cases = hasFlag("--window-context-set")
    ? SeededEvalSet.windowContextCases
    : hasFlag("--post-cursor-set")
        ? SeededEvalSet.postCursorCases
        : adherenceSet
            ? SeededEvalSet.adherenceCases
            : SeededEvalSet.cases
if limit > 0 { cases = Array(cases.prefix(limit)) }
let results = await EvalRunner.run(
    cases: cases,
    engine: engine,
    customInstruction: systemPrompt,
    style: promptStyle,
    length: evalLength,
    examples: evalExamples
)
let summary = EvalSummary(results: results)

print("engine: \(engineLabel)   prompt: \(promptStyle.rawValue)   cases: \(results.count)")
print("suffix: \(promptStyle == .instruction ? "sent as after-cursor context" : "filtering only")")
if !evalExamples.isEmpty {
    print("inputs: examples=\(evalExamples.count) chars")
}
print()
printTable(results)
print()
print(summary.scoreboardDescription)

let qualityPassed = summary.passes(gates)
// The adherence set measures one thing: no style/contamination violation. A
// violation is not diluted by a valid-rate threshold, and the set is not run
// through the general gate.
let adherencePassed = !adherenceSet || summary.forbiddenOutputCount == 0
print(String(repeating: "-", count: 32))
print("gates: failures<=\(gates.maxFailures)  forbidden<=\(gates.maxForbiddenOutputs)  valid>=\(String(format: "%.0f%%", gates.minValidRate * 100))")
print("valid rate: \(String(format: "%.1f%%", summary.validRate * 100))  \(qualityPassed ? "PASS" : "FAIL")")
if adherenceSet {
    print("adherence: violations==0  \(adherencePassed ? "PASS" : "FAIL")  (\(summary.forbiddenOutputCount) violating cases of \(summary.caseCount))")
}

// Aggregate engine throughput: real decode rate, robust to 0-token cases that
// would otherwise drag a per-case median to 0.
let totalTokens = Double(results.reduce(0) { $0 + $1.tokenCount })
let totalGeneration = results.reduce(0.0) { $0 + max($1.duration - $1.timeToFirstToken, 0) }
let aggregateThroughput: Double? = totalGeneration > 0 ? totalTokens / totalGeneration : nil

// Enforce performance gates only for the local model release lane (llama). The
// mock/openai lanes report provenance but are not held to machine thresholds.
let perfGates = (engine is LlamaCppEngine) ? PerformanceGates.modelRelease : PerformanceGates()
let performance = PerformanceSummary(
    averageTokensPerSecond: aggregateThroughput,
    medianTokensPerSecond: summary.averageThroughput > 0 ? summary.medianThroughput : nil,
    averageTimeToFirstToken: summary.averageTTFT,
    averageLatency: summary.averageLatency,
    peakResidentMemoryBytes: peakResidentMemoryBytes(),
    coldLoadSeconds: coldLoadSeconds
)
let perfPassed = perfGates.passes(
    tokensPerSecond: aggregateThroughput,
    coldLoadSeconds: coldLoadSeconds
)
// A run only passes overall when quality AND any required performance gates pass.
// With no required perf gates (mock/openai) `perfPassed` is trivially true.
let gatesPassed = qualityPassed && perfPassed && adherencePassed

print("perf gates: \(perfGates.requirementsDescription)  \(perfPassed ? "PASS" : "FAIL")")
if let tp = aggregateThroughput { print(String(format: "throughput: %.1f tok/s", tp)) }
if let cl = coldLoadSeconds { print(String(format: "cold load: %.2f s", cl)) }

if hasFlag("--json") {
    let gitCommit = shellOutput("git", "rev-parse", "HEAD")
    let provenance = MachineProvenance.capture(
        gitCommit: gitCommit,
        llamaBuild: envText("COTYPE_LLAMA_BUILD", default: "b10665"),
        model: modelProvenance
    )
    let report = EvalRunReport(
        provenance: provenance,
        config: EvalRunConfig(
            temperature: 0,
            maxTokens: Int(maxTokens),
            caseLimit: limit > 0 ? limit : nil,
            caseSetCount: results.count
        ),
        performance: performance,
        gates: perfGates,
        gatesPassed: gatesPassed,
        record: summary.jsonRecord(results: results)
    )
    if let data = try? report.jsonEncoded(),
       let json = String(data: data, encoding: .utf8) {
        print("\n---- JSON ----")
        print(json)
    }
}

(engine as? LlamaCppEngine)?.close()
exit(gatesPassed ? 0 : 1)

/// Print a per-case aligned table of the headline fields.
func printTable(_ results: [EvalResult]) {
    let headers = ["#", "id", "outcome", "valid", "forbidden", "editSim", "TTFT", "tok/s", "latency"]
    var rows: [[String]] = [headers]
    for (index, result) in results.enumerated() {
        rows.append([
            "\(index + 1)",
            result.`case`.id,
            outcomeLabel(result.outcome),
            result.metrics.valid ? "true" : "false",
            result.metrics.forbiddenCount > 0 ? "\(result.metrics.forbiddenCount)" : "-",
            String(format: "%.3f", result.metrics.editSimilarity),
            String(format: "%.3fs", result.timeToFirstToken),
            String(format: "%.1f", result.tokensPerSecond),
            String(format: "%.3fs", result.duration),
        ])
    }

    var widths = [Int](repeating: 0, count: headers.count)
    for row in rows {
        for (column, cell) in row.enumerated() where column < widths.count {
            widths[column] = max(widths[column], cell.count)
        }
    }

    for row in rows {
        let line = row.enumerated()
            .map { column, cell in cell.padding(toLength: widths[column], withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
        print(line)
    }
}

func outcomeLabel(_ outcome: EvalOutcome) -> String {
    switch outcome {
    case .suggestion: return "sug"
    case .noSuggestion: return "none"
    case .failure: return "fail"
    }
}
