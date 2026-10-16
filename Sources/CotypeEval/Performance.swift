import Foundation
import Darwin

// MARK: - Machine / run provenance

/// Where and how a benchmark run was produced, so a machine-readable result can
/// be compared across commits, machines, and model pins. Every field is nullable
/// where it may not be measurable — nothing is fabricated when a value is
/// unavailable.
public struct ModelProvenance: Codable, Equatable, Sendable {
    /// Path passed to the engine.
    public var path: String?
    /// File name (last path component).
    public var file: String?
    /// Source HF repository (when known, e.g. a catalog model).
    public var repo: String?
    /// Pinned revision.
    public var revision: String?
    /// SHA-256 of the model file (null when the file is absent / not hashed).
    public var sha256: String?

    public init(path: String? = nil, file: String? = nil, repo: String? = nil, revision: String? = nil, sha256: String? = nil) {
        self.path = path
        self.file = file
        self.repo = repo
        self.revision = revision
        self.sha256 = sha256
    }
}

/// The machine, OS, and engine build that produced a run.
public struct MachineProvenance: Codable, Equatable, Sendable {
    public var gitCommit: String?
    public var osName: String
    public var osVersion: String
    public var machineArch: String
    public var physicalRAMBytes: UInt64?
    public var cpuBrand: String?
    public var cpuCount: Int?
    public var llamaBuild: String?
    public var model: ModelProvenance
    public var runTimestamp: Date

    public init(
        gitCommit: String? = nil,
        osName: String,
        osVersion: String,
        machineArch: String,
        physicalRAMBytes: UInt64? = nil,
        cpuBrand: String? = nil,
        cpuCount: Int? = nil,
        llamaBuild: String? = nil,
        model: ModelProvenance = ModelProvenance(),
        runTimestamp: Date = Date()
    ) {
        self.gitCommit = gitCommit
        self.osName = osName
        self.osVersion = osVersion
        self.machineArch = machineArch
        self.physicalRAMBytes = physicalRAMBytes
        self.cpuBrand = cpuBrand
        self.cpuCount = cpuCount
        self.llamaBuild = llamaBuild
        self.model = model
        self.runTimestamp = runTimestamp
    }

    /// Capture the current OS / hardware / arch / RAM / CPU from the host. Values
    /// that cannot be read are left nil rather than fabricated.
    public static func capture(gitCommit: String?, llamaBuild: String?, model: ModelProvenance = ModelProvenance(), runTimestamp: Date = Date()) -> MachineProvenance {
        MachineProvenance(
            gitCommit: gitCommit,
            osName: Self.osName(),
            osVersion: Self.osVersion(),
            machineArch: Self.machineArch(),
            physicalRAMBytes: Self.physicalRAM(),
            cpuBrand: Self.cpuBrand(),
            cpuCount: Self.cpuCount(),
            llamaBuild: llamaBuild,
            model: model,
            runTimestamp: runTimestamp
        )
    }

    // MARK: - Host queries

    private static func osName() -> String {
        #if os(macOS)
        return "macOS"
        #else
        return ProcessInfo.processInfo.operatingSystemName
        #endif
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func machineArch() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    private static func physicalRAM() -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func cpuBrand() -> String? {
        var value = [CChar](repeating: 0, count: 256)
        var size = value.count
        guard sysctlbyname("machdep.cpu.brand_string", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    private static func cpuCount() -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname("hw.logicalcpu", &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

// MARK: - Run config

/// The knobs that produced a run, so a result is reproducible and diffable.
public struct EvalRunConfig: Codable, Equatable, Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var caseLimit: Int?
    public var caseSetCount: Int?
    public var seed: UInt64?

    public init(temperature: Double? = nil, maxTokens: Int? = nil, caseLimit: Int? = nil, caseSetCount: Int? = nil, seed: UInt64? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.caseLimit = caseLimit
        self.caseSetCount = caseSetCount
        self.seed = seed
    }
}

// MARK: - Performance summary

/// Performance measurements for a run. Nullable where not measurable so the
/// caller can distinguish "measured" from "not available" rather than faking a
/// value.
public struct PerformanceSummary: Codable, Equatable, Sendable {
    public var averageTokensPerSecond: Double?
    public var medianTokensPerSecond: Double?
    public var averageTimeToFirstToken: Double?
    public var averageLatency: Double?
    public var peakResidentMemoryBytes: Double?
    public var coldLoadSeconds: Double?

    public init(
        averageTokensPerSecond: Double? = nil,
        medianTokensPerSecond: Double? = nil,
        averageTimeToFirstToken: Double? = nil,
        averageLatency: Double? = nil,
        peakResidentMemoryBytes: Double? = nil,
        coldLoadSeconds: Double? = nil
    ) {
        self.averageTokensPerSecond = averageTokensPerSecond
        self.medianTokensPerSecond = medianTokensPerSecond
        self.averageTimeToFirstToken = averageTimeToFirstToken
        self.averageLatency = averageLatency
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.coldLoadSeconds = coldLoadSeconds
    }
}

// MARK: - Performance gates

/// Explicit performance thresholds for the model release lane. A nil threshold
/// means that gate is not required. A required gate whose metric is unavailable
/// (nil) FAILS — metrics are never faked when unavailable.
public struct PerformanceGates: Codable, Equatable, Sendable {
    /// Minimum average generated tokens/second (inclusive).
    public var minTokensPerSecond: Double?
    /// Maximum cold model-load time in seconds (inclusive).
    public var maxColdLoadSeconds: Double?

    public init(minTokensPerSecond: Double? = nil, maxColdLoadSeconds: Double? = nil) {
        self.minTokensPerSecond = minTokensPerSecond
        self.maxColdLoadSeconds = maxColdLoadSeconds
    }

    /// Defaults for the model release lane: at least 20 tokens/s and a cold load
    /// under 15 s.
    public static let modelRelease = PerformanceGates(minTokensPerSecond: 20, maxColdLoadSeconds: 15)

    /// Evaluate the gates. A required gate with a missing (nil) metric fails, so
    /// we never report an unavailable measurement as passing.
    public func passes(tokensPerSecond: Double?, coldLoadSeconds: Double?) -> Bool {
        if let min = minTokensPerSecond, (tokensPerSecond ?? -1) < min { return false }
        if let max = maxColdLoadSeconds, (coldLoadSeconds ?? .infinity) > max { return false }
        return true
    }

    /// A human-readable description of what this gate requires.
    public var requirementsDescription: String {
        var parts: [String] = []
        if let min = minTokensPerSecond { parts.append("tokens/s >= \(String(format: "%.0f", min))") }
        if let max = maxColdLoadSeconds { parts.append("cold load <= \(String(format: "%.0f", max))s") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}

/// One whole machine-readable eval run: provenance + config + summary + cases +
/// performance + gate outcome.
public struct EvalRunReport: Codable {
    public var provenance: MachineProvenance
    public var config: EvalRunConfig
    public var performance: PerformanceSummary
    public var gates: PerformanceGates
    public var gatesPassed: Bool
    public var record: EvalSummary.JSONRecord

    public init(
        provenance: MachineProvenance,
        config: EvalRunConfig,
        performance: PerformanceSummary,
        gates: PerformanceGates,
        gatesPassed: Bool,
        record: EvalSummary.JSONRecord
    ) {
        self.provenance = provenance
        self.config = config
        self.performance = performance
        self.gates = gates
        self.gatesPassed = gatesPassed
        self.record = record
    }

    public func jsonEncoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
