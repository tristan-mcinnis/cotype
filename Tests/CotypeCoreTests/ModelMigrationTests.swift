import XCTest
import CryptoKit
import Foundation
@testable import CotypeCore

/// The model catalog changed its managed filename from the base
/// `gemma-4-E2B-i1-Q4_K_M.gguf` to the instruction-tuned
/// `gemma-4-E2B-it-Q4_K_M.gguf`. Existing users' verified base model is now
/// orphaned: installing the IT model would otherwise leave ~6.6 GB of weights
/// on disk. These tests guard the safe migration/cleanup path AND the integrity
/// rule that a size+mtime marker is only a UX cache, never an integrity
/// decision.
final class ModelMigrationTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "cotype-migration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suite {
            DefaultsSuiteCleanup.remove(suite: suite)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: DefaultsSuiteCleanup.plistURL(forSuite: suite).path),
                "the test suite's preferences plist must not outlive the test"
            )
        }
    }

    func testSuiteCleanupRemovesThePreferencesPlist() throws {
        let name = "cotype-migration-cleanup-\(UUID().uuidString)"
        let probe = try XCTUnwrap(UserDefaults(suiteName: name))
        probe.set("x", forKey: "k")
        probe.synchronize()
        let plist = DefaultsSuiteCleanup.plistURL(forSuite: name).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist), "precondition: the suite writes a plist")

        DefaultsSuiteCleanup.remove(suite: name)

        XCTAssertFalse(FileManager.default.fileExists(atPath: plist))
    }

    private var legacyURL: URL {
        directory.appendingPathComponent(ModelMigration.legacyManagedFilename)
    }

    private var legacyMarkerKey: String {
        "model.verified.sha.\(ModelMigration.legacyManagedFilename)"
    }

    private func writeLegacyFile() {
        try? Data("legacy base weights".utf8).write(to: legacyURL)
    }

    private func writeLegacyMarker() {
        let json = #"{"sha":"61bf05f5e916e0b7faba9324c7c11ae0dbc9d93337094192182911aa6c98c96f","size":100,"modified":0}"#
        defaults.set(json, forKey: legacyMarkerKey)
    }

    /// Writes a marker for `spec` bound to the file's current size + mtime.
    private func writeCurrentMarker(for spec: ModelSpec) throws {
        let modified = try Self.modifiedTime(spec.destinationURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: spec.destinationURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let json = #"{"sha":"\#(spec.expectedSHA256)","size":\#(size),"modified":\#(modified)}"#
        defaults.set(json, forKey: "model.verified.sha.\(spec.managedFilename)")
    }

    private func makeSpec(body: Data = Data("it weights".utf8)) -> ModelSpec {
        ModelSpec(
            modelName: "IT Test",
            repo: "unsloth/gemma-4-E2B-it-GGUF",
            revision: "0314792d7f1f7e229411f620751375812bb9faf2",
            sourceFilename: "gemma-4-E2B-it-Q4_K_M.gguf",
            managedFilename: "gemma-4-E2B-it-Q4_K_M.gguf",
            expectedSHA256: sha256Hex(body),
            expectedSize: Int64(body.count),
            license: "Apache-2.0",
            sourcePageURL: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF",
            ramUseBytes: 1_000_000,
            diskRequirementBytes: 2_000_000,
            installDirectory: directory
        )
    }

    // MARK: - Cleanup (post-verification only, exact filename only)

    func testCleanupRemovesExactLegacyFileAndMarker() {
        writeLegacyFile()
        writeLegacyMarker()

        ModelMigration.cleanupLegacyArtifact(in: directory, defaults: defaults)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "the legacy managed file must be removed after a verified install")
        XCTAssertNil(defaults.string(forKey: legacyMarkerKey),
                     "the obsolete legacy marker must be removed")
    }

    func testCleanupRemovesOnlyTheExactLegacyFilename() {
        writeLegacyFile()
        let unrelated = directory.appendingPathComponent("my-backup.bin")
        try? Data("user data".utf8).write(to: unrelated)

        ModelMigration.cleanupLegacyArtifact(in: directory, defaults: defaults)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "cleanup must never remove arbitrary files")
    }

    func testCleanupIsIdempotentWhenNothingToRemove() {
        ModelMigration.cleanupLegacyArtifact(in: directory, defaults: defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Legacy-only detection (Setup treats it as requiring the upgrade)

    @MainActor
    func testManagerReportsLegacyOnlyAsUpgradeRequiredNotInstalled() {
        writeLegacyFile()
        let manager = ModelDownloadManager(spec: makeSpec(), installer: FakeInstaller(), defaults: defaults)

        XCTAssertFalse(manager.isInstalled, "the base model must not be treated as the current (IT) model")
        XCTAssertTrue(manager.hasLegacyOnlyModel, "a legacy-only machine must be reported as needing an IT upgrade")
    }

    @MainActor
    func testManagerDoesNotReportLegacyModelAfterCurrentInstalled() throws {
        let body = Data("it weights".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)
        try writeCurrentMarker(for: spec)

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertTrue(manager.isInstalled)
        XCTAssertFalse(manager.hasLegacyOnlyModel)
    }

    // MARK: - Cleanup only after a verified install

    @MainActor
    func testManagerCleansLegacyAfterSuccessfulInstall() async {
        writeLegacyFile()
        writeLegacyMarker()
        let manager = ModelDownloadManager(spec: makeSpec(), installer: FakeInstaller(), defaults: defaults)

        manager.start()
        await waitUntil { manager.state == .ready }

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "cleanup must run after a successful install")
        XCTAssertNil(defaults.string(forKey: legacyMarkerKey))
    }

    @MainActor
    func testManagerDoesNotCleanLegacyOnFailedInstall() async {
        writeLegacyFile()
        writeLegacyMarker()
        let failing = FakeInstaller(stream: { _ in FakeInstaller.failingStream(TestError.boom) })
        let manager = ModelDownloadManager(spec: makeSpec(), installer: failing, defaults: defaults)

        manager.start()
        await waitUntil { if case .failed = manager.state { return true } else { return false } }

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path),
                      "cleanup must NEVER run before the new model is downloaded and verified")
        XCTAssertNotNil(defaults.string(forKey: legacyMarkerKey))
    }

    @MainActor
    func testManagerCleansLegacyWhenCurrentAlreadyInstalled() async throws {
        let body = Data("it weights".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)
        try writeCurrentMarker(for: spec)
        writeLegacyFile()
        writeLegacyMarker()

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertTrue(manager.isInstalled)

        manager.start()
        await waitUntil { manager.state == .ready || manager.state == .idle }

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "the lingering legacy base model must be cleaned once the current model is verified")
        XCTAssertNil(defaults.string(forKey: legacyMarkerKey))
    }

    // MARK: - Integrity: marker is only a cache, not an integrity decision

    @MainActor
    func testSameSizeSameMtimeTamperingIsRejectedOnRefresh() async throws {
        // A "verified" IT model is present. Its size+mtime marker matches the
        // marker, but the file is then tampered with: same byte length, same
        // mtime (attacker restored both), different content. The marker cache
        // still "passes", but a real SHA-256 verification must reject it.
        let original = Data(String(repeating: "a", count: 256).utf8)
        let spec = makeSpec(body: original)
        try original.write(to: spec.destinationURL)
        // Capture the original mtime BEFORE any tampering; the marker records it.
        let originalMtime = try Self.modifiedTime(spec.destinationURL)
        try writeCurrentMarker(for: spec)

        // Marker cache passes (size + mtime + sha of the *expected* content).
        let manager = ModelDownloadManager(spec: spec, installer: ModelInstaller(), defaults: defaults)
        XCTAssertTrue(manager.isInstalled, "this documents that the marker alone remains bypassable")

        // Tamper: same byte length, then restore the original mtime so the
        // size+mtime marker still "passes".
        let tampered = Data(String(repeating: "b", count: 256).utf8)
        XCTAssertEqual(tampered.count, original.count)
        try tampered.write(to: spec.destinationURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: originalMtime)],
            ofItemAtPath: spec.destinationURL.path
        )

        // The marker cache still reports installed (size+mtime restored)...
        XCTAssertTrue(manager.isInstalled, "a restored size+mtime still passes the marker cache")

        // ...but refresh (launch path) must perform a real SHA-256 verification
        // and reject the tampered file rather than reporting it loadable.
        manager.refreshInstallationStatus()
        await waitUntil { manager.state != .verifying }
        XCTAssertNotEqual(manager.state, .ready,
                          "a tampered same-size/same-mtime model must not be reported loadable")
        XCTAssertNil(defaults.string(forKey: "model.verified.sha.\(spec.managedFilename)"),
                     "the stale marker must be dropped once verification rejects the file")
    }

    // MARK: - Helpers

    private static func modifiedTime(_ url: URL) throws -> Double {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: Int = 4000) async {
        for _ in 0..<timeout {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for condition")
    }

    private enum TestError: LocalizedError {
        case boom
        var errorDescription: String? { "boom" }
    }
}

// MARK: - Fake installer (mirrors the test double in ModelInstallerTests)

private final class FakeInstaller: ModelInstalling {
    var installed: Bool
    var onInstall: (ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error>

    init(
        installed: Bool = false,
        stream: @escaping (ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error> = { _ in FakeInstaller.successStream() }
    ) {
        self.installed = installed
        self.onInstall = stream
    }

    func install(_ spec: ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error> { onInstall(spec) }
    func isInstalled(_ spec: ModelSpec) -> Bool { installed }

    static func successStream() -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ModelInstallProgress(phase: .downloading, downloadedBytes: 10, totalBytes: 100))
            continuation.yield(ModelInstallProgress(phase: .downloading, downloadedBytes: 100, totalBytes: 100))
            continuation.finish()
        }
    }

    static func failingStream(_ error: Error) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ModelInstallProgress(phase: .downloading, downloadedBytes: 5, totalBytes: 100))
            continuation.finish(throwing: error)
        }
    }
}
