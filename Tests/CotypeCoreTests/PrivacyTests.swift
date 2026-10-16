import XCTest
import Foundation
@testable import CotypeCore

final class SensitiveContextTests: XCTestCase {

    func testDetectorAllowsSafeContext() {
        let detector = SensitiveContextDetector()
        let verdict = detector.evaluate(
            appIdentifier: "com.apple.dt.Xcode",
            isSecureTextField: false,
            containsProtectedContent: false,
            axState: .readable
        )
        XCTAssertEqual(verdict, .safe)
    }

    func testDetectorGatesSecureTextField() {
        let detector = SensitiveContextDetector()
        let verdict = detector.evaluate(
            appIdentifier: "com.apple.mail",
            isSecureTextField: true,
            containsProtectedContent: false,
            axState: .readable
        )
        XCTAssertEqual(verdict, .gated(.secureTextField))
    }

    func testDetectorGatesProtectedContent() {
        let detector = SensitiveContextDetector()
        let verdict = detector.evaluate(
            appIdentifier: "com.agilebits.onepassword",
            isSecureTextField: false,
            containsProtectedContent: true,
            axState: .readable
        )
        XCTAssertEqual(verdict, .gated(.protectedContent))
    }

    func testDetectorGatesBuiltInSensitiveApp() {
        let detector = SensitiveContextDetector()
        let verdict = detector.evaluate(
            appIdentifier: "com.apple.keychainaccess",
            isSecureTextField: false,
            containsProtectedContent: false,
            axState: .readable
        )
        XCTAssertEqual(verdict, .gated(.sensitiveApp))
    }

    func testDetectorGatesUserExclusion() {
        let detector = SensitiveContextDetector(userExclusions: ["com.example.private"])
        let verdict = detector.evaluate(
            appIdentifier: "com.example.private",
            isSecureTextField: false,
            containsProtectedContent: false,
            axState: .readable
        )
        XCTAssertEqual(verdict, .gated(.userExcludedApp))
    }

    func testDetectorFailsClosedOnUntrustedAX() {
        let detector = SensitiveContextDetector()
        // Even a normally-safe app must not be completed or logged when AX is
        // unreadable.
        let verdict = detector.evaluate(
            appIdentifier: "com.apple.TextEdit",
            isSecureTextField: false,
            containsProtectedContent: false,
            axState: .untrusted
        )
        XCTAssertEqual(verdict, .unreadable)
    }

    func testDetectorFailsClosedOnUnresolvableElement() {
        let detector = SensitiveContextDetector()
        let verdict = detector.evaluate(
            appIdentifier: "com.apple.finder",
            isSecureTextField: false,
            containsProtectedContent: false,
            axState: .elementUnresolvable
        )
        XCTAssertEqual(verdict, .unreadable)
    }

    func testDetectorUserExclusionCanRejectOverBuiltInSafeApp() {
        // A user exclusion is honored even for an app not on the built-in list.
        let detector = SensitiveContextDetector(userExclusions: ["com.some.editor"])
        XCTAssertEqual(
            detector.evaluate(appIdentifier: "com.some.editor", isSecureTextField: false, containsProtectedContent: false, axState: .readable),
            .gated(.userExcludedApp)
        )
    }

    func testBuiltInSensitiveAppListIsDisjointFromSafeApps() {
        let safe = ["com.apple.dt.Xcode", "com.apple.TextEdit", "com.google.Chrome", "com.microsoft.VSCode"]
        for bundleID in safe {
            XCTAssertFalse(SensitiveContextDetector.isBuiltInSensitive(bundleID))
        }
        XCTAssertTrue(SensitiveContextDetector.isBuiltInSensitive("com.apple.keychainaccess"))
        XCTAssertTrue(SensitiveContextDetector.isBuiltInSensitive("com.1password.1password"))
    }
}

// MARK: - Sensitive ancestry (secure / protected ancestor walk)

private struct StubAXAncestryReader: AXAncestryReader {
    let steps: [AXAncestryToken: AXAncestryStep]
    func readFacts(for element: AXAncestryToken) -> AXAncestryStep {
        steps[element] ?? AXAncestryStep(
            facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false)
        )
    }
}

final class SensitiveAncestryTests: XCTestCase {

    private let readable = AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: true)

    private func token(_ i: UInt) -> AXAncestryToken { AXAncestryToken(identity: i) }

    func testClearSingleElementChainIsSafe() {
        let start = token(0)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: start,
            reader: StubAXAncestryReader(steps: [start: AXAncestryStep(facts: readable)])
        )
        XCTAssertEqual(verdict, .safe)
    }

    func testNaturallyTerminatingDeepChainIsSafe() {
        let t0 = token(0), t1 = token(1), t2 = token(2)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: t0,
            reader: StubAXAncestryReader(steps: [
                t0: AXAncestryStep(facts: readable, parent: t1),
                t1: AXAncestryStep(facts: readable, parent: t2),
                t2: AXAncestryStep(facts: readable),
            ])
        )
        XCTAssertEqual(verdict, .safe)
    }

    func testAncestryChainLackingOptionalAttributesReturnsSafe() {
        // A normal editor chain where every ancestor lacks a secure subrole and
        // protected content must be safe (not fail-closed): optional attribute
        // absence is not a security signal.
        let t0 = token(0), t1 = token(1), t2 = token(2)
        func node(_ parent: AXAncestryToken?) -> AXAncestryStep {
            AXAncestryStep(
                facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: true),
                parent: parent
            )
        }
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: t0,
            reader: StubAXAncestryReader(steps: [t0: node(t1), t1: node(t2), t2: node(nil)])
        )
        XCTAssertEqual(verdict, .safe)
    }

    func testFocusedElementSecureTextFieldGates() {
        let start = token(0)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: start,
            reader: StubAXAncestryReader(steps: [
                start: AXAncestryStep(facts: AXElementFacts(isSecureTextField: true, containsProtectedContent: false, isReadable: true))
            ])
        )
        XCTAssertEqual(verdict, .gated(.secureTextField))
    }

    func testNestedSecureTextFieldAncestorGates() {
        let t0 = token(0), t1 = token(1)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: t0,
            reader: StubAXAncestryReader(steps: [
                t0: AXAncestryStep(facts: readable, parent: t1),
                t1: AXAncestryStep(facts: AXElementFacts(isSecureTextField: true, containsProtectedContent: false, isReadable: true)),
            ])
        )
        XCTAssertEqual(verdict, .gated(.secureTextField))
    }

    func testNestedProtectedContentAncestorGates() {
        let t0 = token(0), t1 = token(1)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: t0,
            reader: StubAXAncestryReader(steps: [
                t0: AXAncestryStep(facts: readable, parent: t1),
                t1: AXAncestryStep(facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: true, isReadable: true)),
            ])
        )
        XCTAssertEqual(verdict, .gated(.protectedContent))
    }

    func testUnreadableAncestorFailsClosed() {
        let t0 = token(0), t1 = token(1)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: t0,
            reader: StubAXAncestryReader(steps: [
                t0: AXAncestryStep(facts: readable, parent: t1),
                t1: AXAncestryStep(facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false)),
            ])
        )
        XCTAssertEqual(verdict, .unreadable)
    }

    func testCycleFailsClosed() {
        let t0 = token(0), t1 = token(1)
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: t0,
            reader: StubAXAncestryReader(steps: [
                t0: AXAncestryStep(facts: readable, parent: t1),
                t1: AXAncestryStep(facts: readable, parent: t0),
            ])
        )
        XCTAssertEqual(verdict, .unreadable)
    }

    func testDepthBoundFailsClosed() {
        let start = token(0)
        var steps: [AXAncestryToken: AXAncestryStep] = [:]
        for i in 0...SensitiveAncestryPolicy.maxDepth {
            let current = token(UInt(i))
            let parent = token(UInt(i + 1))
            steps[current] = AXAncestryStep(facts: readable, parent: parent)
        }
        let verdict = SensitiveAncestryPolicy.evaluate(
            start: start,
            reader: StubAXAncestryReader(steps: steps)
        )
        XCTAssertEqual(verdict, .unreadable)
    }

    func testDetectorCombinesAncestryVerdict() {
        let detector = SensitiveContextDetector()
        XCTAssertEqual(
            detector.evaluate(appIdentifier: "com.apple.TextEdit", isSecureTextField: false, containsProtectedContent: false, axState: .readable, ancestry: .gated(.secureTextField)),
            .gated(.secureTextField)
        )
        XCTAssertEqual(
            detector.evaluate(appIdentifier: "com.apple.TextEdit", isSecureTextField: false, containsProtectedContent: false, axState: .readable, ancestry: .unreadable),
            .unreadable
        )
        XCTAssertEqual(
            detector.evaluate(appIdentifier: "com.apple.TextEdit", isSecureTextField: false, containsProtectedContent: false, axState: .readable, ancestry: .safe),
            .safe
        )
    }
}

/// Writes slowly so tests can prove record paths never block on disk I/O.
private final class BlockingFileWriter: PersonalizationFileWriter, @unchecked Sendable {
    let delay: TimeInterval
    init(delay: TimeInterval = 0.5) { self.delay = delay }
    func write(_ data: Data, to url: URL) throws {
        Thread.sleep(forTimeInterval: delay)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

final class PersonalizationMigrationTests: XCTestCase {

    /// Owner-only mode for the privacy data files.
    private func posixMode(of url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? NSNumber else { return nil }
        return mode.intValue
    }

    private func tempFile(_ name: String, _ ext: String = "json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-privacy-\(name)-\(UUID().uuidString).\(ext)")
    }

    private func makeStore(_ name: String) -> PersonalizationStore {
        PersonalizationStore(
            fileURL: tempFile("\(name)-samples"),
            configURL: tempFile("\(name)-config"),
            metricsURL: tempFile("\(name)-metrics")
        )
    }

    // The privacy data files must be owner-only (0600): the samples file holds
    // prefix/completion text, and the metrics/config files hold per-app usage
    // and exclusions.
    func testPersonalizationFilesAreOwnerOnly() {
        let samples = tempFile("perm-samples")
        let config = tempFile("perm-config")
        let metrics = tempFile("perm-metrics")
        let store = PersonalizationStore(fileURL: samples, configURL: config, metricsURL: metrics)
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        store.recordMetric(.shown, appIdentifier: "app")
        store.setUserExcludedApps(["com.example.private"])
        store.flush()

        XCTAssertEqual(posixMode(of: samples), 0o600, "personalization.json must be owner-only")
        XCTAssertEqual(posixMode(of: config), 0o600)
        XCTAssertEqual(posixMode(of: metrics), 0o600)
    }

    func testMigrationRewritesOwnerOnlyPermissions() throws {
        let url = tempFile("perm-migrate")
        let v1 = #"[{"prefix":"p1","completion":"c1","accepted":true,"appIdentifier":"app","timestamp":751200000.0}]"#
        try Data(v1.utf8).write(to: url)

        // Loading triggers the writeAll migration; the rewritten file must be 0600.
        let store = PersonalizationStore(
            fileURL: url, configURL: tempFile("perm-migrate-config"), metricsURL: tempFile("perm-migrate-metrics")
        )
        XCTAssertEqual(store.samples().count, 1)
        XCTAssertEqual(posixMode(of: url), 0o600)
    }

    // v1 records carried a Boolean `accepted` instead of `outcome`. They must
    // migrate to the versioned enum: accepted=true -> .accepted, false -> .dismissed.
    func testV1ArrayMigratesToVersionedOutcome() throws {
        let url = tempFile("v1-array")
        let v1 = #"[{"prefix":"p1","completion":"c1","accepted":true,"appIdentifier":"xcode","timestamp":751200000.0},{"prefix":"p2","completion":"c2","accepted":false,"appIdentifier":"xcode","timestamp":751200001.0}]"#
        try Data(v1.utf8).write(to: url)

        let store = PersonalizationStore(fileURL: url, configURL: tempFile("v1-config"), metricsURL: tempFile("v1-metrics"))
        let samples = store.samples()

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.first?.outcome, .dismissed) // newest (ts 751200001) had accepted=false
        XCTAssertEqual(samples.last?.outcome, .accepted)     // older had accepted=true
        XCTAssertTrue(samples.allSatisfy { $0.schemaVersion == PersonalizationSample.currentSchemaVersion })
        XCTAssertTrue(samples.allSatisfy { $0.accepted == ($0.outcome == .accepted) })

        // Migrated file should be JSON-lines, not a JSON array.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.hasPrefix("["), "legacy array should migrate to JSON Lines")
    }

    // Legacy JSON-lines v1 records must also decode.
    func testV1JSONLinesMigrates() throws {
        let url = tempFile("v1-lines")
        let line = "{\"prefix\":\"p\",\"completion\":\"c\",\"accepted\":true,\"appIdentifier\":\"app\",\"timestamp\":751200000.0}\n"
        try Data(line.utf8).write(to: url)

        let store = PersonalizationStore(fileURL: url, configURL: tempFile("v1-config"), metricsURL: tempFile("v1-metrics"))
        XCTAssertEqual(store.samples().first?.outcome, .accepted)
    }

    func testV2SamplesRoundTrip() throws {
        let url = tempFile("v2-samples")
        let metricsURL = tempFile("v2-metrics")
        let store = PersonalizationStore(fileURL: url, configURL: tempFile("v2-config"), metricsURL: metricsURL)
        store.recordCanceled(appIdentifier: "app")
        store.recordShown(appIdentifier: "app")
        store.recordFailed(appIdentifier: "app")
        store.recordDismissed(prefix: "p", completion: "c", appIdentifier: "app")
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        store.flush()

        let reloaded = PersonalizationStore(fileURL: url, configURL: tempFile("v2-config"), metricsURL: metricsURL)
        let samples = reloaded.samples()
        // Only content-bearing outcomes produce content samples.
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(Set(samples.map { $0.outcome }), [.dismissed, .accepted])
        XCTAssertTrue(samples.allSatisfy { $0.schemaVersion == 2 })

        // Metrics reflect every outcome, content-free.
        let summary = reloaded.usageSummary()
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.shown, 1)
        XCTAssertEqual(summary.accepted, 1)
        XCTAssertEqual(summary.dismissed, 1)
        XCTAssertEqual(summary.canceled, 1)
        XCTAssertEqual(summary.failed, 1)
    }

    func testRecordCapsPrefixAndCompletion() {
        let store = makeStore("caps")
        let longPrefix = String(repeating: "a", count: PersonalizationStore.maxStoredPrefixLength + 500)
        let longCompletion = String(repeating: "b", count: PersonalizationStore.maxStoredCompletionLength + 100)

        store.recordAccepted(prefix: longPrefix, completion: longCompletion, appIdentifier: "app")

        let sample = store.samples().first!
        XCTAssertEqual(sample.prefix.count, PersonalizationStore.maxStoredPrefixLength)
        XCTAssertEqual(sample.completion.count, PersonalizationStore.maxStoredCompletionLength)
    }

    func testUsageSummaryCountsOutcomes() {
        let store = makeStore("summary")
        store.recordShown(appIdentifier: "app")
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        store.recordDismissed(prefix: "p", completion: "c", appIdentifier: "app")
        store.recordCanceled(appIdentifier: "app")
        store.recordFailed(appIdentifier: "app")

        let summary = store.usageSummary()
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.shown, 1)
        XCTAssertEqual(summary.accepted, 1)
        XCTAssertEqual(summary.dismissed, 1)
        XCTAssertEqual(summary.canceled, 1)
        XCTAssertEqual(summary.failed, 1)
    }

    // When content logging is off (the default), records that go through the
    // content-free metric path still count toward the usage summary but store no
    // content samples.
    func testMetricsRecordedEvenWhenNoContentStored() {
        let store = makeStore("metrics-only")
        // Simulate logging-off by recording only content-free metrics for the
        // accepted/dismissed outcomes (no prefix/completion).
        store.recordMetric(.shown, appIdentifier: "app")
        store.recordMetric(.accepted, appIdentifier: "app")
        store.recordMetric(.dismissed, appIdentifier: "app")
        store.recordMetric(.canceled, appIdentifier: "app")
        store.recordMetric(.failed, appIdentifier: "app")

        XCTAssertEqual(store.count, 0, "No content samples should be persisted")
        XCTAssertTrue(store.samples().isEmpty)

        let summary = store.usageSummary()
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.shown, 1)
        XCTAssertEqual(summary.accepted, 1)
        XCTAssertEqual(summary.dismissed, 1)
        XCTAssertEqual(summary.canceled, 1)
        XCTAssertEqual(summary.failed, 1)
    }

    func testMetricsAreVersionedAndBoundedPerApp() {
        let store = makeStore("bounded")
        // Insert > maxPerAppEntries distinct apps so the bound kicks in.
        for index in 0..<(PersonalizationStore.maxPerAppEntries + 50) {
            store.recordMetric(.shown, appIdentifier: "com.example.app\(index)")
        }
        let metrics = store.metricCounts
        XCTAssertLessThanOrEqual(metrics.perApp.count, PersonalizationStore.maxPerAppEntries)
        XCTAssertEqual(metrics.schemaVersion, PersonalizationMetrics.currentSchemaVersion)
        XCTAssertEqual(metrics.total, PersonalizationStore.maxPerAppEntries + 50)
    }

    // A record call must not block on a slow disk writer (the async/coalesced
    // writer moves persistence off the caller).
    func testRecordDoesNotBlockOnBlockedWriter() {
        let store = PersonalizationStore(
            fileURL: tempFile("block-samples"),
            configURL: tempFile("block-config"),
            metricsURL: tempFile("block-metrics"),
            fileWriter: BlockingFileWriter(delay: 0.5)
        )
        let start = Date()
        store.recordMetric(.shown, appIdentifier: "app")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.2, "record must not block on the disk writer")
    }

    // No updates may be lost: after flush, the on-disk state reflects every
    // recorded metric even when writes are slow and coalesced.
    func testNoUpdatesAreLostAfterFlush() {
        let metricsURL = tempFile("flush-metrics")
        let store = PersonalizationStore(
            fileURL: tempFile("flush-samples"),
            configURL: tempFile("flush-config"),
            metricsURL: metricsURL,
            fileWriter: BlockingFileWriter(delay: 0.02)
        )
        for index in 0..<50 {
            store.recordMetric(.shown, appIdentifier: "com.example.app\(index)")
        }
        store.flush()

        // A fresh store reading the same metrics file must observe all 50.
        let reloaded = PersonalizationStore(
            fileURL: tempFile("flush-samples-r"),
            configURL: tempFile("flush-config-r"),
            metricsURL: metricsURL
        )
        XCTAssertEqual(reloaded.metricCounts.total, 50)
        XCTAssertEqual(reloaded.usageSummary().shown, 50)
    }

    // Loading a store must remediate an existing 0644 owner-only file immediately
    // (migration requirement), without needing a mutation.
    func testExistingPersonalizationFileRemediatedToOwnerOnly() throws {
        let url = tempFile("remediate-samples")
        try "{}\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path)
        XCTAssertEqual(posixMode(of: url), 0o644, "precondition: file starts at 0644")

        let store = PersonalizationStore(fileURL: url, configURL: tempFile("remediate-config"), metricsURL: tempFile("remediate-metrics"))
        _ = store   // loading alone must remediate
        XCTAssertEqual(posixMode(of: url), 0o600, "load must remediate an existing 0644 content file")
    }

    func testExistingOverridesFileRemediatedToOwnerOnly() throws {
        let url = tempFile("remediate-overrides")
        try "{}".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path)
        XCTAssertEqual(posixMode(of: url), 0o644, "precondition: file starts at 0644")

        let store = AppOverridesStore(fileURL: url)
        _ = store
        XCTAssertEqual(posixMode(of: url), 0o600, "load must remediate an existing 0644 app-overrides file")
    }

    // A record racing a clear must never resurrect pre-clear data; any event that
    // lands after the reset survives.
    func testRecordsRacingClearDoNotResurrectPreClearData() throws {
        let url = tempFile("race-samples")
        let store = PersonalizationStore(
            fileURL: url, configURL: tempFile("race-config"), metricsURL: tempFile("race-metrics"),
            fileWriter: BlockingFileWriter(delay: 0.01)
        )
        store.recordAccepted(prefix: "pre", completion: "1", appIdentifier: "app")
        store.flush()
        XCTAssertTrue(String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("\"prefix\":\"pre\""))

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = store.clear()
            group.leave()
        }
        for index in 0..<30 {
            store.recordAccepted(prefix: "post\(index)", completion: "c", appIdentifier: "app")
        }
        group.wait()
        store.flush()

        let disk = String(data: try Data(contentsOf: url), encoding: .utf8)!
        XCTAssertFalse(disk.contains("\"prefix\":\"pre\""), "stale pre-clear data must not survive a clear; disk=\(disk)")
        for sample in store.samples() {
            XCTAssertTrue(disk.contains(sample.prefix), "a post-clear event must survive")
        }
    }

    // A write-failure callback that queries the store must not deadlock (the
    // callback is now invoked outside the queue lock).
    func testWriteFailureCallbackCanQueryTheStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-deadlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PersonalizationStore(fileURL: dir, configURL: tempFile("dl-config"), metricsURL: tempFile("dl-metrics"))
        store.onWriteFailure = { [weak store] _ in
            _ = store?.failureCount   // queries the store -> queue.sync; must not deadlock
        }
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        store.flush()   // force the failing write so the callback fires

        XCTAssertGreaterThanOrEqual(store.failureCount, 1)
    }

    func testDeleteAllRemovesFileContentsAndVerifies() {
        let store = makeStore("delete")
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        XCTAssertEqual(store.count, 1)
        XCTAssertFalse(store.isOnDiskEmpty())

        let ok = store.deleteAll()
        XCTAssertTrue(ok, "Delete All should verify and report success")
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.isOnDiskEmpty())
        XCTAssertEqual(store.metricCounts.total, 0, "Delete All resets aggregate metrics too")
        XCTAssertEqual(store.usageSummary().total, 0)
    }

    func testRetentionKeepUntilDeletedRetains() {
        let store = makeStore("keep")
        store.setRetentionPolicy(.keepUntilDeleted)
        let old = PersonalizationSample(prefix: "p", completion: "c", outcome: .accepted, appIdentifier: "app",
                                        timestamp: Date().addingTimeInterval(-100_000_000))
        store.record(old)
        XCTAssertEqual(store.count, 1)
        // Metric is counted even though the sample pre-dates any retention cutoff.
        XCTAssertEqual(store.usageSummary().accepted, 1)
    }

    func testRetentionSevenDaysPrunesOldData() {
        let store = makeStore("prune")
        store.setRetentionPolicy(.sevenDays)
        let old = PersonalizationSample(prefix: "p", completion: "c", outcome: .accepted, appIdentifier: "app",
                                        timestamp: Date().addingTimeInterval(-10 * 24 * 60 * 60))
        let fresh = PersonalizationSample(prefix: "p", completion: "c", outcome: .accepted, appIdentifier: "app",
                                          timestamp: Date())
        store.record(old)
        store.record(fresh) // recording triggers a prune that drops the old one
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.samples().first?.outcome, .accepted)
    }

    func testRetentionOffBlocksContentRecordingButStillCountsMetrics() {
        let store = makeStore("off")
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        XCTAssertEqual(store.count, 1)

        store.setRetentionPolicy(.off)
        XCTAssertEqual(store.count, 0, "Switching to Off prunes stored content samples")

        // Recording content while Off is a no-op, but the metric stays counted.
        store.recordAccepted(prefix: "x", completion: "y", appIdentifier: "app")
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.usageSummary().accepted, 2)
    }

    func testExportIncludesMetricsAndSamples() {
        let store = makeStore("export")
        store.recordMetric(.shown, appIdentifier: "app")
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")

        let data = store.exportData()
        let decoded = try? JSONDecoder().decode(PersonalizationExport.self, from: data)
        XCTAssertNotNil(decoded, "export should be a decodable versioned envelope")
        XCTAssertEqual(decoded?.metrics.total, 2)
        XCTAssertEqual(decoded?.metrics.shown, 1)
        XCTAssertEqual(decoded?.metrics.accepted, 1)
        XCTAssertEqual(decoded?.samples.count, 1)
    }

    func testWriteFailureIsObservable() throws {
        // Point the samples file at a path that is actually a directory so the
        // append cannot succeed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-write-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let expectation = expectation(description: "write-failure callback")
        let store = PersonalizationStore(fileURL: dir, configURL: tempFile("writefail-config"), metricsURL: tempFile("writefail-metrics"))
        store.onWriteFailure = { _ in expectation.fulfill() }

        XCTAssertEqual(store.failureCount, 0)
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "app")
        store.flush()   // force the (async) write so the failure is observable

        // Failure is recorded and surfaced, not thrown into the caller.
        XCTAssertGreaterThanOrEqual(store.failureCount, 1)
        XCTAssertNotNil(store.currentWriteError)
        wait(for: [expectation], timeout: 1.0)
    }

    func testOverridesFileIsOwnerOnly() {
        let url = tempFile("overrides-perm")
        let store = AppOverridesStore(fileURL: url)
        store.setOverride(AppOverride(systemPrompt: "prompt"), for: "com.example.one")
        XCTAssertEqual(posixMode(of: url), 0o600, "app-overrides.json may hold user-authored prompts and must be owner-only")
    }

    func testOverridesStoreExposesAllKeys() {
        let url = tempFile("keys")
        let store = AppOverridesStore(fileURL: url)
        store.setOverride(AppOverride(systemPrompt: "prompt"), for: "com.example.one")
        store.setOverride(AppOverride(enabled: false), for: "com.example.two")

        let keys = store.allKeys()
        XCTAssertTrue(keys.contains("com.example.one"))
        XCTAssertTrue(keys.contains("com.example.two"))
        XCTAssertFalse(keys.contains("com.example.none"))

        store.removeOverride(for: "com.example.one")
        XCTAssertFalse(store.allKeys().contains("com.example.one"))

        let reloaded = AppOverridesStore(fileURL: url)
        XCTAssertTrue(reloaded.allKeys().contains("com.example.two"))
    }
}
