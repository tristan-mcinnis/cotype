import Foundation

/// The terminal state of a single completion attempt. Replaces the old
/// `PersonalizationSample.accepted: Bool` so the Privacy & Data usage summary
/// can distinguish shown, accepted, dismissed, canceled, and failed completions.
///
/// `shown` is a content-free observation recorded when a candidate is first
/// rendered. `accepted`/`dismissed` carry the (capped) prefix and completion;
/// `canceled` and `failed` are content-free so a mid-stream abort or a pipeline
/// error never persists partial or sensitive text.
public enum PersonalizationOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    case shown
    case accepted
    case dismissed
    case canceled
    case failed

    /// True when the completion was really accepted. Used for the "learn from
    /// accepted completions" path that previously read `accepted: Bool`.
    public var isAccepted: Bool { self == .accepted }
}

/// One completion observation, recorded for fine-tuning and the usage summary.
///
/// Persisted as a versioned record. Migration: v1 records stored a Boolean
/// `accepted`; v2 stores `outcome` plus `schemaVersion`. Decoding a v1 record
/// maps `accepted == true` to `.accepted` and `accepted == false` to `.dismissed`
/// (the historical reject signal could not distinguish dismissed/canceled/failed,
/// so dismissed is the best faithful mapping).
public struct PersonalizationSample: Equatable, Sendable {
    /// Current on-disk schema version.
    public static let currentSchemaVersion = 2
    /// The oldest schema version this store can still read (v1 = legacy Bool).
    public static let minimumReadableSchemaVersion = 1

    public var prefix: String
    public var completion: String
    public var outcome: PersonalizationOutcome
    public var appIdentifier: String
    public var timestamp: Date
    public var schemaVersion: Int

    /// Backward-compatible read of the historical "accepted" signal.
    public var accepted: Bool { outcome.isAccepted }

    /// v2 initializer.
    public init(
        prefix: String,
        completion: String,
        outcome: PersonalizationOutcome,
        appIdentifier: String,
        timestamp: Date = Date(),
        schemaVersion: Int = PersonalizationSample.currentSchemaVersion
    ) {
        self.prefix = prefix
        self.completion = completion
        self.outcome = outcome
        self.appIdentifier = appIdentifier
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
    }

    /// Legacy v1 convenience initializer, retained for source compatibility
    /// with callers/tests that still pass `accepted`. Records are normalized to
    /// the versioned schema on decode/encode.
    public init(
        prefix: String,
        completion: String,
        accepted: Bool,
        appIdentifier: String,
        timestamp: Date = Date()
    ) {
        self.init(
            prefix: prefix,
            completion: completion,
            outcome: accepted ? .accepted : .dismissed,
            appIdentifier: appIdentifier,
            timestamp: timestamp,
            schemaVersion: Self.currentSchemaVersion
        )
    }
}

extension PersonalizationSample: Codable {
    private enum CodingKeys: String, CodingKey {
        case prefix, completion, outcome, appIdentifier, timestamp, schemaVersion, accepted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefix = try container.decode(String.self, forKey: .prefix)
        completion = try container.decode(String.self, forKey: .completion)
        appIdentifier = try container.decode(String.self, forKey: .appIdentifier)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        // Schema version: default to v1 (legacy) when absent so we can migrate.
        let declaredVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.minimumReadableSchemaVersion
        schemaVersion = Self.currentSchemaVersion

        if let outcome = try container.decodeIfPresent(PersonalizationOutcome.self, forKey: .outcome) {
            self.outcome = outcome
        } else if let legacyAccepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) {
            // v1 migration: a rejected completion is most faithfully a dismissal.
            self.outcome = legacyAccepted ? .accepted : .dismissed
        } else {
            // Neither outcome nor accepted present: fail closed by not treating
            // this as an accepted sample; dismissals carry no training signal.
            self.outcome = .dismissed
        }

        _ = declaredVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(completion, forKey: .completion)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(appIdentifier, forKey: .appIdentifier)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

/// How long recorded samples are retained.
///
/// `off` disables retention: switching to it prunes all stored samples.
public enum RetentionPolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case off
    case sevenDays
    case thirtyDays
    case keepUntilDeleted

    /// The cutoff used by pruning. `distantPast` retains everything (a sentinel
    /// for "keep until deleted"); `off` retains nothing.
    func pruneCutoff(now: Date) -> Date {
        switch self {
        case .off: return .distantFuture
        case .sevenDays: return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .thirtyDays: return now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .keepUntilDeleted: return .distantPast
        }
    }

    /// Whether the policy keeps any records at all. `.off` means the store
    /// refuses to write and prunes whatever it already holds.
    var shouldRetain: Bool { self != .off }
}

/// A per-outcome breakdown of usage, used by the Privacy & Data usage summary.
/// Never presented as a model "accuracy" number.
public struct PersonalizationUsageSummary: Equatable, Sendable {
    public var total: Int
    public var shown: Int
    public var accepted: Int
    public var dismissed: Int
    public var canceled: Int
    public var failed: Int

    public init(total: Int = 0, shown: Int = 0, accepted: Int = 0, dismissed: Int = 0, canceled: Int = 0, failed: Int = 0) {
        self.total = total
        self.shown = shown
        self.accepted = accepted
        self.dismissed = dismissed
        self.canceled = canceled
        self.failed = failed
    }
}

/// Content-free aggregate counters for every completion outcome. Bounded and
/// versioned, with no prefix/completion text. These are always recorded — even
/// when content logging is off — so the usage summary reflects real usage
/// without persisting any sensitive content. Per-app counts are capped at
/// `PersonalizationStore.maxPerAppEntries` to keep the metrics file bounded.
public struct PersonalizationMetrics: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var total: Int
    public var shown: Int
    public var accepted: Int
    public var dismissed: Int
    public var canceled: Int
    public var failed: Int
    /// Bounded per-app breakdown (never stores content).
    public var perApp: [String: AppCounts]

    public struct AppCounts: Codable, Equatable, Sendable {
        public var shown: Int
        public var accepted: Int
        public var dismissed: Int
        public var canceled: Int
        public var failed: Int

        public init(shown: Int = 0, accepted: Int = 0, dismissed: Int = 0, canceled: Int = 0, failed: Int = 0) {
            self.shown = shown
            self.accepted = accepted
            self.dismissed = dismissed
            self.canceled = canceled
            self.failed = failed
        }

        public var total: Int { shown + accepted + dismissed + canceled + failed }
    }

    public init(
        schemaVersion: Int = PersonalizationMetrics.currentSchemaVersion,
        total: Int = 0,
        shown: Int = 0,
        accepted: Int = 0,
        dismissed: Int = 0,
        canceled: Int = 0,
        failed: Int = 0,
        perApp: [String: AppCounts] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.total = total
        self.shown = shown
        self.accepted = accepted
        self.dismissed = dismissed
        self.canceled = canceled
        self.failed = failed
        self.perApp = perApp
    }

    public var isEmpty: Bool { total == 0 }

    public func count(for outcome: PersonalizationOutcome) -> Int {
        switch outcome {
        case .shown: return shown
        case .accepted: return accepted
        case .dismissed: return dismissed
        case .canceled: return canceled
        case .failed: return failed
        }
    }
}

/// Append-only log of completion outcomes, plus content-free aggregate metrics.
///
/// Content samples are persisted as newline-delimited JSON (injectable file URL
/// for tests) guarded by a serial queue. Aggregate metrics are persisted to a
/// separate bounded file and are always recorded, independent of content
/// logging. Legacy JSON-array files and legacy v1 (`accepted: Bool`) records are
/// migrated on load.
///
/// Privacy posture:
/// - Storage is capped: `prefix` and `completion` are truncated to fixed, strict
///   bounds so no huge document text is ever written.
/// - Aggregate metrics carry no content and are recorded even when logging is
///   off, so usage is never lost while sensitive context is never persisted.
/// - Write failures are surfaced via `lastWriteError` / `writeFailureCount` and
///   `onWriteFailure` instead of being swallowed silently, but recording never
///   throws into the caller, so typing is never interrupted.
/// - Retention pruning runs on init and on every content record.
/// - `deleteAll` verifies both the samples and metrics files are gone and
///   returns success.

/// Writes encoded payloads to the privacy data files. Injectable so tests can
/// substitute a blocking or recording writer to prove record paths never block
/// on disk I/O.
public protocol PersonalizationFileWriter: Sendable {
    func write(_ data: Data, to url: URL) throws
}

/// Production `PersonalizationFileWriter`: creates the parent directory and
/// writes atomically.
public struct SystemFileWriter: PersonalizationFileWriter {
    public init() {}
    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public final class PersonalizationStore: @unchecked Sendable {

    /// Strict character caps applied at record time. These are deliberately
    /// small — the goal is the minimum useful context, never the whole document.
    public static let maxStoredPrefixLength = 2000
    public static let maxStoredCompletionLength = 500
    /// Maximum number of distinct apps tracked in the bounded metrics file.
    public static let maxPerAppEntries = 200

    private let fileURL: URL
    private let configURL: URL
    private let metricsURL: URL
    private let queue = DispatchQueue(label: "com.cotype.personalization")
    private let writerQueue = DispatchQueue(label: "com.cotype.personalization.writer")
    private let writer: PersonalizationFileWriter
    private var samples: [PersonalizationSample]
    private var config: PersonalizationConfig
    private var metrics: PersonalizationMetrics
    /// Which data files need a background write (guarded by `queue`).
    private var dirtyFiles: Set<PrivacyFile> = []
    /// Whether a writer task is already queued/running (guarded by `queue`).
    private var writeScheduled = false

    /// Set in the Settings UI to observe a recent write failure. Fired on the
    /// store's serial queue; callers must hop to the main actor before touching
    /// UI state.
    public var onWriteFailure: (@Sendable (String) -> Void)?
    private(set) var writeFailureCount = 0
    private(set) var lastWriteError: String?

    /// - Parameters:
    ///   - fileURL: where to persist content samples. Defaults to
    ///     `~/Library/Application Support/Cotype/personalization.json`.
    ///   - configURL: where to persist retention + exclusions. Defaults to the
    ///     same directory's `privacy-config.json`.
    ///   - metricsURL: where to persist content-free aggregate counters. Defaults
    ///     to the same directory's `privacy-metrics.json`.
    public init(
        fileURL: URL? = nil,
        configURL: URL? = nil,
        metricsURL: URL? = nil,
        fileWriter: PersonalizationFileWriter = SystemFileWriter()
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.configURL = configURL ?? Self.defaultConfigURL()
        self.metricsURL = metricsURL ?? Self.defaultMetricsURL()
        self.writer = fileWriter
        self.config = Self.loadConfig(from: self.configURL)
        self.metrics = Self.loadMetrics(from: self.metricsURL)
        if let data = try? Data(contentsOf: self.fileURL) {
            if let decoded = try? JSONDecoder().decode([PersonalizationSample].self, from: data) {
                // Migrate the original JSON-array format once to JSON Lines (a
                // rare one-time synchronous write), then use coalesced writes.
                self.samples = decoded
                try? Self.writeAll(decoded, to: self.fileURL)
                securePermissions(on: self.fileURL)
            } else {
                self.samples = Self.decodeJSONLines(data)
            }
        } else {
            self.samples = []
        }
        // Remediate any existing files that predate the owner-only policy (e.g.
        // an install that wrote at 0644 before this change).
        SecurePermissions.apply(to: self.fileURL)
        SecurePermissions.apply(to: self.configURL)
        SecurePermissions.apply(to: self.metricsURL)
        prune()
        // Drain any writes scheduled by prune so the on-disk state is
        // deterministic immediately after construction.
        flush()
    }

    // MARK: - Outcome recorders

    /// Record a content-free "candidate rendered" metric.
    public func recordShown(appIdentifier: String) {
        recordMetric(.shown, appIdentifier: appIdentifier)
    }

    /// Record an accepted completion (content capped). Content is persisted only
    /// when the pipeline records through the content path.
    public func recordAccepted(prefix: String, completion: String, appIdentifier: String) {
        record(PersonalizationSample(prefix: prefix, completion: completion, outcome: .accepted, appIdentifier: appIdentifier))
    }

    /// Record a dismissed completion (content capped).
    public func recordDismissed(prefix: String, completion: String, appIdentifier: String) {
        record(PersonalizationSample(prefix: prefix, completion: completion, outcome: .dismissed, appIdentifier: appIdentifier))
    }

    /// Record a content-free "superseded / aborted before a candidate" metric.
    public func recordCanceled(appIdentifier: String) {
        recordMetric(.canceled, appIdentifier: appIdentifier)
    }

    /// Record a content-free pipeline-failure metric.
    public func recordFailed(appIdentifier: String) {
        recordMetric(.failed, appIdentifier: appIdentifier)
    }

    /// Legacy "rejected" alias retained for source compatibility: a historical
    /// rejection maps to `.dismissed`.
    public func recordRejected(prefix: String, completion: String, appIdentifier: String) {
        recordDismissed(prefix: prefix, completion: completion, appIdentifier: appIdentifier)
    }

    /// Record a content-free aggregate metric. Safe to call at any time — it
    /// never stores prefix or completion text.
    public func recordMetric(_ outcome: PersonalizationOutcome, appIdentifier: String) {
        queue.sync {
            bumpMetricLocked(outcome, appIdentifier: appIdentifier)
        }
    }

    /// Append a content sample directly (content is capped to the strict bounds).
    /// Also counts toward the aggregate metric for its outcome. When retention
    /// is `.off`, the content sample is dropped but the metric is still counted.
    public func record(_ sample: PersonalizationSample) {
        queue.sync {
            bumpMetricLocked(sample.outcome, appIdentifier: sample.appIdentifier)
            guard config.retentionPolicy.shouldRetain else { return }
            pruneLocked()
            let capped = PersonalizationSample(
                prefix: Self.capPrefix(sample.prefix),
                completion: Self.capCompletion(sample.completion),
                outcome: sample.outcome,
                appIdentifier: sample.appIdentifier,
                timestamp: sample.timestamp,
                schemaVersion: PersonalizationSample.currentSchemaVersion
            )
            samples.append(capped)
            markDirtyLocked(.samples)
        }
    }

    // MARK: - Queries

    /// All content samples, optionally filtered to a single app's bundle
    /// identifier. Returned newest-first. Empty when content logging is off.
    public func samples(forApp appIdentifier: String? = nil) -> [PersonalizationSample] {
        queue.sync {
            let filtered: [PersonalizationSample]
            if let appIdentifier {
                filtered = samples.filter { $0.appIdentifier == appIdentifier }
            } else {
                filtered = samples
            }
            return filtered.reversed()
        }
    }

    /// Number of content samples. Independent of the aggregate metric counters.
    public var count: Int {
        queue.sync { samples.count }
    }

    /// The current bounded aggregate metrics.
    public var metricCounts: PersonalizationMetrics {
        queue.sync { metrics }
    }

    /// Per-outcome breakdown for the usage summary, always accurate (even when
    /// content logging is off) because it reads the aggregate counters.
    public func usageSummary() -> PersonalizationUsageSummary {
        queue.sync {
            PersonalizationUsageSummary(
                total: metrics.total,
                shown: metrics.shown,
                accepted: metrics.accepted,
                dismissed: metrics.dismissed,
                canceled: metrics.canceled,
                failed: metrics.failed
            )
        }
    }

    // MARK: - Retention

    public var retentionPolicy: RetentionPolicy {
        queue.sync { config.retentionPolicy }
    }

    public func setRetentionPolicy(_ policy: RetentionPolicy) {
        queue.sync {
            config.retentionPolicy = policy
            markDirtyLocked(.config)
            pruneLocked()
        }
    }

    /// Remove content samples that exceed the current retention policy. Called
    /// on init and before every content record via the locked internal helper.
    /// Aggregate metrics are unaffected (they carry no content).
    public func prune() {
        queue.sync { pruneLocked() }
    }

    private func pruneLocked() {
        guard config.retentionPolicy != .keepUntilDeleted else { return }
        let cutoff = config.retentionPolicy.pruneCutoff(now: Date())
        let originalCount = samples.count
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count != originalCount {
            markDirtyLocked(.samples)
        }
    }

    // MARK: - User exclusions

    public var userExcludedApps: Set<String> {
        queue.sync { config.userExcludedApps }
    }

    public func setUserExcludedApps(_ apps: Set<String>) {
        queue.sync {
            config.userExcludedApps = apps
            markDirtyLocked(.config)
        }
    }

    // MARK: - Delete / export / write health

    /// Delete every content sample and reset the aggregate counters, verifying
    /// both on-disk files are empty. Returns `true` only when verified.
    @discardableResult
    public func clear() -> Bool {
        // Drain any pending writes first so a writer cannot have stale pre-clear
        // data in flight when the reset lands.
        flush()
        // Reset in-memory state and mark the files dirty. The empty state is then
        // written THROUGH the writer queue (markDirty + flush), so it is ordered
        // with any concurrent record's write — no stale pre-clear rewrite, and a
        // record that arrives after the reset survives. Delete All is a rare,
        // user-initiated action and may block, unlike the record paths.
        queue.sync {
            samples.removeAll()
            metrics = PersonalizationMetrics()
            markDirtyLocked(.samples)
            markDirtyLocked(.metrics)
        }
        flush()
        // Verify the reset authoritatively (in-memory state + on-disk files). A
        // record that raced clear makes this false; its data survives.
        return queue.sync { samples.isEmpty && metrics.isEmpty && verifyFilesEmpty() }
    }

    /// Alias for `clear()` with explicit semantics used by the Privacy & Data UI.
    @discardableResult
    public func deleteAll() -> Bool {
        clear()
    }

    /// True when both the samples and metrics files hold no records. Flushes any
    /// pending writes first so the result reflects the current in-memory state.
    public func isOnDiskEmpty() -> Bool {
        flush()
        return queue.sync { verifyFilesEmpty() }
    }

    /// Readable JSON export of the stored data: a versioned envelope containing
    /// the bounded aggregate metrics and the (content-capped) samples. Used by
    /// the Export action. It serializes the in-memory snapshot (immediately
    /// consistent) and need not flush pending writes. Not used for loading; the
    /// store loads from JSON lines.
    public func exportData() -> Data {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(PersonalizationExport(
                schemaVersion: 1,
                exportedAt: Date(),
                metrics: metrics,
                samples: samples
            ))) ?? Data()
        }
    }

    /// The most recent write error (nil if writes have been healthy).
    public var currentWriteError: String? {
        queue.sync { lastWriteError }
    }

    public var failureCount: Int {
        queue.sync { writeFailureCount }
    }

    // MARK: - Metrics persistence

    private func bumpMetricLocked(_ outcome: PersonalizationOutcome, appIdentifier: String) {
        metrics.total += 1
        switch outcome {
        case .shown: metrics.shown += 1
        case .accepted: metrics.accepted += 1
        case .dismissed: metrics.dismissed += 1
        case .canceled: metrics.canceled += 1
        case .failed: metrics.failed += 1
        }

        var counts = metrics.perApp[appIdentifier] ?? PersonalizationMetrics.AppCounts()
        switch outcome {
        case .shown: counts.shown += 1
        case .accepted: counts.accepted += 1
        case .dismissed: counts.dismissed += 1
        case .canceled: counts.canceled += 1
        case .failed: counts.failed += 1
        }
        if metrics.perApp[appIdentifier] == nil, metrics.perApp.count >= Self.maxPerAppEntries {
            // Bound the file to a fixed number of distinct apps; evict the
            // smallest so a long-running install does not grow unboundedly.
            if let evict = metrics.perApp.min(by: { $0.value.total < $1.value.total })?.key {
                metrics.perApp.removeValue(forKey: evict)
            }
        }
        metrics.perApp[appIdentifier] = counts

        markDirtyLocked(.metrics)
    }

    private static func loadMetrics(from url: URL) -> PersonalizationMetrics {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersonalizationMetrics.self, from: data) else {
            return PersonalizationMetrics()
        }
        return decoded
    }

    // MARK: - Coalesced background writer

    private enum PrivacyFile: CaseIterable {
        case samples, metrics, config
    }

    private func url(for file: PrivacyFile) -> URL {
        switch file {
        case .samples: return fileURL
        case .metrics: return metricsURL
        case .config: return configURL
        }
    }

    /// The latest encoded payload for a file. Must be called while holding
    /// `queue`. An empty metrics object is serialized as truly empty data so the
    /// file reads as empty (e.g. after Delete All).
    private func data(for file: PrivacyFile) -> Data {
        switch file {
        case .samples: return Self.samplesData(samples)
        case .metrics: return metrics.isEmpty ? Data() : ((try? JSONEncoder().encode(metrics)) ?? Data())
        case .config: return (try? JSONEncoder().encode(config)) ?? Data()
        }
    }

    /// Mark a file as dirty and schedule a background write if none is in
    /// flight. Must be called while holding `queue`. Never performs disk I/O, so
    /// callers (e.g. the completion controller on the main actor) never block
    /// on a file write.
    private func markDirtyLocked(_ file: PrivacyFile) {
        dirtyFiles.insert(file)
        guard !writeScheduled else { return }
        writeScheduled = true
        writerQueue.async { [weak self] in self?.writerLoop() }
    }

    /// Write the currently dirty files to disk, reading the latest in-memory
    /// state under `queue`. Returns true when new files became dirty during the
    /// write. Runs on `writerQueue`.
    private func drainOneBatch() -> Bool {
        let work = queue.sync { () -> [(PrivacyFile, Data)] in
            let files = dirtyFiles
            dirtyFiles = []
            return files.map { ($0, self.data(for: $0)) }
        }
        for (file, payload) in work {
            do {
                try writer.write(payload, to: url(for: file))
                securePermissions(on: url(for: file))
            } catch {
                noteWriteFailure(error.localizedDescription)
            }
        }
        return queue.sync { !self.dirtyFiles.isEmpty }
    }

    /// Runs on `writerQueue`: drains dirty files until clean, then clears the
    /// in-flight flag, re-arming only if a mutation arrived during the drain so
    /// no update is lost when writes succeed. A write failure is surfaced via
    /// `noteWriteFailure` (the failed payload is not automatically retried), so
    /// persistence is best-effort on a real I/O error.
    private func writerLoop() {
        while queue.sync(execute: { !dirtyFiles.isEmpty }) {
            _ = drainOneBatch()
        }
        queue.sync {
            writeScheduled = false
            if !dirtyFiles.isEmpty {
                writeScheduled = true
                writerQueue.async { [weak self] in self?.writerLoop() }
            }
        }
    }

    /// Synchronously drain all pending writes so on-disk state is deterministic.
    /// Used by tests, export, and delete (all of which must observe a flushed
    /// file). Blocks the caller; the runtime record paths never call it.
    public func flush() {
        writerQueue.sync {
            while queue.sync(execute: { !self.dirtyFiles.isEmpty }) {
                _ = self.drainOneBatch()
            }
        }
    }

    private func noteWriteFailure(_ message: String) {
        // Capture the current callback under the lock, then invoke it OUTSIDE the
        // lock so a callback that queries the store (which does queue.sync) cannot
        // deadlock on the re-entrant serial queue.
        let callback = queue.sync { () -> (@Sendable (String) -> Void)? in
            writeFailureCount += 1
            lastWriteError = message
            return onWriteFailure
        }
        callback?(message)
    }

    /// Restrict a personal data file to owner-only read/write (mode 0600).
    /// Best-effort and non-fatal: a failure to set permissions does not surface
    /// as a write failure (the write itself already succeeded) and is therefore
    /// safe to call while holding `queue`.
    private func securePermissions(on url: URL) {
        SecurePermissions.apply(to: url)
    }

    private func verifyFilesEmpty() -> Bool {
        verifyEmpty(fileURL) && verifyEmpty(metricsURL)
    }

    private func verifyEmpty(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true } // absent = empty
        if data.isEmpty { return true }
        let trimmed = data.split(separator: 0x0A).filter { !$0.isEmpty }
        return trimmed.isEmpty
    }

    // MARK: - Config / sample helpers

    private static func loadConfig(from url: URL) -> PersonalizationConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersonalizationConfig.self, from: data) else {
            return PersonalizationConfig()
        }
        return decoded
    }

    private static func decodeJSONLines(_ data: Data) -> [PersonalizationSample] {
        data.split(separator: 0x0A).compactMap { line in
            try? JSONDecoder().decode(PersonalizationSample.self, from: Data(line))
        }
    }

    /// JSON-Lines encoding of the samples (one record per line). The coalesced
    /// writer always rewrites the full file from this payload.
    private static func samplesData(_ samples: [PersonalizationSample]) -> Data {
        var data = Data()
        let encoder = JSONEncoder()
        for sample in samples {
            if let encoded = try? encoder.encode(sample) {
                data.append(encoded)
                data.append(0x0A)
            }
        }
        return data
    }

    /// One-time synchronous write used for the rare JSON-array migration.
    private static func writeAll(_ samples: [PersonalizationSample], to url: URL) throws {
        try samplesData(samples).write(to: url, options: .atomic)
    }

    // MARK: - Caps

    static func capPrefix(_ value: String) -> String {
        guard value.count > maxStoredPrefixLength else { return value }
        return String(value.prefix(maxStoredPrefixLength))
    }

    static func capCompletion(_ value: String) -> String {
        guard value.count > maxStoredCompletionLength else { return value }
        return String(value.prefix(maxStoredCompletionLength))
    }

    // MARK: - Default URLs

    public static func defaultFileURL() -> URL {
        defaultDirectory().appendingPathComponent("personalization.json")
    }

    public static func defaultConfigURL() -> URL {
        defaultDirectory().appendingPathComponent("privacy-config.json")
    }

    public static func defaultMetricsURL() -> URL {
        defaultDirectory().appendingPathComponent("privacy-metrics.json")
    }

    private static func defaultDirectory() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cotype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Non-content privacy configuration retained separately from the content
/// samples, so turning logging off or Delete All never wipes the user's
/// retention/exclusion preferences.
public struct PersonalizationConfig: Codable, Equatable, Sendable {
    public var retentionPolicy: RetentionPolicy
    public var userExcludedApps: Set<String>

    public init(retentionPolicy: RetentionPolicy = .keepUntilDeleted, userExcludedApps: Set<String> = []) {
        self.retentionPolicy = retentionPolicy
        self.userExcludedApps = userExcludedApps
    }
}

/// Versioned envelope written by `exportData()`: bounded, content-free aggregate
/// metrics plus the (content-capped) samples. Never used for loading.
public struct PersonalizationExport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var metrics: PersonalizationMetrics
    public var samples: [PersonalizationSample]

    public init(schemaVersion: Int = 1, exportedAt: Date = Date(), metrics: PersonalizationMetrics, samples: [PersonalizationSample]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.metrics = metrics
        self.samples = samples
    }
}
