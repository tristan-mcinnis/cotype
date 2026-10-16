import XCTest
import CryptoKit
@testable import CotypeCore

// MARK: - Stub URLProtocol

/// A per-test URLProtocol stub so the installer's real `GGUFDownloader` hits a
/// local handler instead of the network. Kept separate from the one used by the
/// network tests so each file owns its handler state.
private final class InstallerStubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = try Self.lock.withLock { try XCTUnwrap(Self.handler)(request) }
            let http = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            ))
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty {
                client?.urlProtocol(self, didLoad: response.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Fake installer

/// A controllable `ModelInstalling` double for exercising the manager's state
/// machine without a real network or the real installer. Non-isolated: the
/// protocol's methods are nonisolated, and in practice it is only driven from the
/// main actor by the manager, so there is no real data race.
private final class FakeInstaller: ModelInstalling {
    var installed = false
    var installCallCount = 0
    var onInstall: (ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error>

    init(stream: @escaping (ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error> = { _ in FakeInstaller.successStream() }) {
        self.onInstall = stream
    }

    func install(_ spec: ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        installCallCount += 1
        return onInstall(spec)
    }

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

// MARK: - Tests

final class ModelInstallerTests: XCTestCase {

    private var session: URLSession!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallerStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuite = "cotype-model-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        InstallerStubURLProtocol.lock.withLock { InstallerStubURLProtocol.handler = nil }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let defaultsSuite { defaults.removePersistentDomain(forName: defaultsSuite) }
    }

    // MARK: Helpers

    private func makeSpec(
        body: Data,
        managedFilename: String = "test.gguf",
        revision: String = "main",
        expectedSize: Int64? = nil,
        expectedSHA: String? = nil,
        diskRequirement: Int64 = 1_000_000
    ) -> ModelSpec {
        ModelSpec(
            modelName: "Test Model",
            repo: "owner/repo",
            revision: revision,
            sourceFilename: "src.gguf",
            managedFilename: managedFilename,
            expectedSHA256: expectedSHA ?? sha256Hex(body),
            expectedSize: expectedSize ?? Int64(body.count),
            license: "MIT",
            sourcePageURL: "https://example.test/owner/repo",
            ramUseBytes: 1000,
            diskRequirementBytes: diskRequirement,
            installDirectory: directory
        )
    }

    private func collectInstall(_ spec: ModelSpec, freeSpace: Int64 = 1_000_000_000) async throws -> [ModelInstallProgress] {
        let installer = ModelInstaller(
            downloader: GGUFDownloader(session: session),
            freeSpace: { _ in freeSpace }
        )
        var values: [ModelInstallProgress] = []
        for try await value in installer.install(spec) {
            values.append(value)
        }
        return values
    }

    // MARK: Catalog + descriptor

    func testBuiltInCatalogMatchesPinnedGemmaModel() {
        // The pinned catalog is the instruction-tuned Q4_K_M artifact, not the
        // base model the original pin pointed at.
        let spec = ModelSpec.gemma4E2BIt
        XCTAssertEqual(spec.repo, "unsloth/gemma-4-E2B-it-GGUF")
        XCTAssertEqual(spec.revision, "0314792d7f1f7e229411f620751375812bb9faf2")
        XCTAssertEqual(spec.sourceFilename, "gemma-4-E2B-it-Q4_K_M.gguf")
        XCTAssertEqual(spec.managedFilename, "gemma-4-E2B-it-Q4_K_M.gguf")
        XCTAssertEqual(spec.expectedSHA256, "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8")
        XCTAssertEqual(spec.expectedSize, 3_106_738_272)
        XCTAssertEqual(spec.sourceFilename, spec.managedFilename)
    }

    func testLegacyBaseModelCatalogIsNotThePinnedCatalog() {
        // Guard against regressing back to the base (non-instruction-tuned) pin:
        // the pinned catalog must be the IT variant with the expected shape.
        let spec = ModelSpec.gemma4E2BIt
        XCTAssertTrue(spec.modelName.contains("Instruction-Tuned"))
        XCTAssertTrue(spec.sourceFilename.contains("-it-"))
        XCTAssertFalse(spec.repo.contains("mradermacher"), "base/repo pin must not be reintroduced")
    }

    func testDescriptorUsesPinnedRevisionAndSourceFilename() {
        let spec = ModelSpec.gemma4E2BIt
        let descriptor = spec.descriptor()
        XCTAssertEqual(descriptor.revision, spec.revision)
        XCTAssertEqual(descriptor.filename, spec.sourceFilename)
        XCTAssertEqual(descriptor.destination, spec.destinationURL)
        XCTAssertTrue(
            descriptor.resolvedURL.absoluteString.hasSuffix("/resolve/\(spec.revision)/\(spec.sourceFilename)"),
            "resolved URL should be pinned to the revision: \(descriptor.resolvedURL)"
        )
    }

    func testDescriptorDefaultsRevisionToMain() {
        let url = ModelDescriptor(
            repo: "owner/model",
            filename: "model.gguf",
            destination: directory.appendingPathComponent("model.gguf")
        ).resolvedURL.absoluteString
        XCTAssertEqual(url, "https://huggingface.co/owner/model/resolve/main/model.gguf")
    }

    // MARK: Installer

    func testInstallerDownloadsVerifiesAndSucceeds() async throws {
        let body = Data("complete model bytes".utf8)
        let spec = makeSpec(body: body)
        InstallerStubURLProtocol.lock.withLock {
            InstallerStubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        }

        let progress = try await collectInstall(spec)

        XCTAssertEqual(try Data(contentsOf: spec.destinationURL), body)
        XCTAssertEqual(progress.last?.isFinal, true)
        XCTAssertTrue(progress.contains { $0.phase == .downloading })
        XCTAssertTrue(progress.contains { $0.phase == .verifying })
        XCTAssertEqual(progress.last?.downloadedBytes, Int64(body.count))
    }

    func testInstallerFailsSafelyOnChecksumMismatch() async throws {
        let body = Data("corrupt model".utf8)
        let spec = makeSpec(body: body, expectedSHA: String(repeating: "0", count: 64))
        InstallerStubURLProtocol.lock.withLock {
            InstallerStubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        }

        do {
            _ = try await collectInstall(spec)
            XCTFail("Expected checksumMismatch")
        } catch let error as ModelDownloadError {
            if case .checksumMismatch = error {} else {
                XCTFail("Expected checksumMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spec.destinationURL.path),
                       "corrupt file must be removed so the engine never loads it")
    }

    func testInstallerRejectsWrongSizeAndRemovesFile() async throws {
        let body = Data("size mismatch".utf8)
        let spec = makeSpec(body: body, expectedSize: Int64(body.count) + 10)
        InstallerStubURLProtocol.lock.withLock {
            InstallerStubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        }

        do {
            _ = try await collectInstall(spec)
            XCTFail("Expected sizeMismatch")
        } catch let error as ModelDownloadError {
            if case .sizeMismatch = error {} else {
                XCTFail("Expected sizeMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spec.destinationURL.path))
    }

    func testInstallerRefusesWhenDiskIsLow() async throws {
        let body = Data("too big to fit".utf8)
        let spec = makeSpec(body: body, diskRequirement: 10_000_000)
        InstallerStubURLProtocol.lock.withLock {
            InstallerStubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        }

        do {
            _ = try await collectInstall(spec, freeSpace: 1_000)
            XCTFail("Expected insufficientDiskSpace")
        } catch let error as ModelDownloadError {
            if case .insufficientDiskSpace = error {} else {
                XCTFail("Expected insufficientDiskSpace, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spec.destinationURL.path),
                       "no bytes should be written when the download is refused")
    }

    func testInstallerResumesPartialFileViaRange() async throws {
        let fpart = Data("partial-".utf8)
        let rest = Data("model".utf8)
        let spec = makeSpec(body: fpart + rest, managedFilename: "resume.gguf")
        try fpart.write(to: spec.destinationURL)

        InstallerStubURLProtocol.lock.withLock {
            InstallerStubURLProtocol.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(fpart.count)-")
                return .init(
                    status: 206,
                    headers: [
                        "Content-Range": "bytes \(fpart.count)-\(fpart.count + rest.count - 1)/\(fpart.count + rest.count)",
                        "Content-Length": "\(rest.count)",
                    ],
                    body: rest
                )
            }
        }

        _ = try await collectInstall(spec)
        XCTAssertEqual(try Data(contentsOf: spec.destinationURL), fpart + rest)
    }

    // MARK: Manager state machine

    @MainActor
    func testManagerTransitionsToReadyAndFiresOnReady() async {
        let fake = FakeInstaller()
        let manager = ModelDownloadManager(spec: makeSpec(body: Data("x".utf8)), installer: fake, defaults: defaults)
        var readyFired = false
        manager.onReady = { readyFired = true }

        manager.start()
        await waitUntil { manager.state == .ready }

        XCTAssertEqual(fake.installCallCount, 1)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(readyFired)
    }

    @MainActor
    func testManagerVerifiesUnmarkedExistingModelWithoutRedownload() async throws {
        let body = Data("x".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)
        let fake = FakeInstaller()
        fake.installed = true
        let manager = ModelDownloadManager(spec: spec, installer: fake, defaults: defaults)
        var readyFired = false
        manager.onReady = { readyFired = true }

        manager.start()
        XCTAssertEqual(manager.state, .verifying)
        await waitUntil { manager.state == .ready }

        XCTAssertEqual(fake.installCallCount, 0, "already-installed model must not re-download")
        XCTAssertTrue(manager.isInstalled, "successful verification should persist the fast-path marker")
        XCTAssertTrue(readyFired)
    }

    @MainActor
    func testManagerReportsFailure() async {
        let fake = FakeInstaller(stream: { _ in FakeInstaller.failingStream(TestError.boom) })
        let manager = ModelDownloadManager(spec: makeSpec(body: Data("x".utf8)), installer: fake, defaults: defaults)

        manager.start()
        await waitUntil { if case .failed = manager.state { return true } else { return false } }

        guard case .failed(let message) = manager.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertFalse(message.isEmpty)
    }

    @MainActor
    func testManagerPauseAndResume() async {
        let fake = FakeInstaller(stream: { _ in FakeInstaller.successStream() })
        let manager = ModelDownloadManager(spec: makeSpec(body: Data("x".utf8)), installer: fake, defaults: defaults)

        manager.start()
        XCTAssertEqual(manager.state, .downloading)

        manager.pause()
        XCTAssertEqual(manager.state, .paused)
        XCTAssertTrue(manager.isPaused)

        manager.resume()
        await waitUntil { manager.state == .ready }
        XCTAssertGreaterThanOrEqual(fake.installCallCount, 2, "resume should start a fresh install")
    }

    @MainActor
    func testManagerRetryAfterFailure() async {
        var shouldFail = true
        let fake = FakeInstaller { _ in
            shouldFail ? FakeInstaller.failingStream(TestError.boom) : FakeInstaller.successStream()
        }
        let manager = ModelDownloadManager(spec: makeSpec(body: Data("x".utf8)), installer: fake, defaults: defaults)

        manager.start()
        await waitUntil { if case .failed = manager.state { return true } else { return false } }

        shouldFail = false
        manager.retry()
        await waitUntil { manager.state == .ready }
        XCTAssertEqual(fake.installCallCount, 2)
    }

    @MainActor
    func testManagerCancelResetsToIdleAndRemovesPartialFile() {
        let fake = FakeInstaller(stream: { _ in FakeInstaller.hangingStream() })
        let spec = makeSpec(body: Data("needs-removal".utf8))
        let destination = spec.destinationURL
        try? Data("partial".utf8).write(to: destination)
        let manager = ModelDownloadManager(spec: spec, installer: fake, defaults: defaults)

        manager.start()
        XCTAssertEqual(manager.state, .downloading)

        manager.cancel()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testManagerRemoveDeletesInstalledModel() {
        let spec = makeSpec(body: Data("model".utf8))
        let destination = spec.destinationURL
        try? Data("model".utf8).write(to: destination)
        let fake = FakeInstaller()
        fake.installed = true
        let manager = ModelDownloadManager(spec: spec, installer: fake, defaults: defaults)

        manager.remove()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Verified-marker metadata binding

    @MainActor
    func testInstalledMarkerIsBoundToFileMetadata() throws {
        let body = Data("marker-bound model bytes".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)
        let modified = try Self.modifiedTime(spec.destinationURL)

        writeMarker(
            for: spec,
            sha: spec.expectedSHA256,
            size: Int64(body.count),
            modified: modified
        )

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertTrue(manager.isInstalled, "a marker matching size and mtime is a valid fast-path")
    }

    @MainActor
    func testInstalledMarkerInvalidatedByMetadataMismatch() throws {
        let body = Data("same size, different content".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)

        // Marker claims the model was verified, but its recorded modification
        // time does not match the file's current mtime. The marker is invalid:
        // the fast path must not trust a stale/mismatched marker.
        writeMarker(
            for: spec,
            sha: spec.expectedSHA256,
            size: Int64(body.count),
            modified: 0
        )

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertFalse(manager.isInstalled, "a metadata mismatch must invalidate the fast-path marker")
    }

    @MainActor
    func testInstalledMarkerInvalidatedBySizeMismatch() throws {
        let body = Data("size mismatch".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)
        writeMarker(
            for: spec,
            sha: spec.expectedSHA256,
            size: Int64(body.count) + 999,
            modified: try Self.modifiedTime(spec.destinationURL)
        )

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertFalse(manager.isInstalled, "a size mismatch must invalidate the fast-path marker")
    }

    @MainActor
    func testMarkerInvalidatedWhenModelReplacedInPlace() throws {
        // After a valid fast path, the file is replaced by a same-size different
        // blob. Its mtime changes, so the previously-valid marker no longer
        // matches the metadata and is invalidated.
        let original = Data(String(repeating: "a", count: 32).utf8)
        let spec = makeSpec(body: original)
        try original.write(to: spec.destinationURL)
        writeMarker(
            for: spec,
            sha: spec.expectedSHA256,
            size: Int64(original.count),
            modified: try Self.modifiedTime(spec.destinationURL)
        )

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertTrue(manager.isInstalled)

        // Simulate a swapped model file: same byte count, different content,
        // with a fresh modification time (deterministic across filesystems).
        let swapped = Data(String(repeating: "b", count: 32).utf8)
        try swapped.write(to: spec.destinationURL)
        let newModified = try Self.modifiedTime(spec.destinationURL) + 1234.5
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: newModified)],
            ofItemAtPath: spec.destinationURL.path
        )

        XCTAssertFalse(manager.isInstalled, "a swapped-in same-size model must invalidate the marker")
    }

    @MainActor
    func testNoMarkerMeansMustRehash() throws {
        let body = Data("unmarked model".utf8)
        let spec = makeSpec(body: body)
        try body.write(to: spec.destinationURL)

        let manager = ModelDownloadManager(spec: spec, installer: FakeInstaller(), defaults: defaults)
        XCTAssertFalse(manager.isInstalled, "an unmarked existing model must not be trusted without a rehash")
    }

    private func writeMarker(for spec: ModelSpec, sha: String, size: Int64, modified: Double) {
        // Replicates ModelDownloadManager.verifiedKey so tests can inject a
        // marker directly. Encoding matches the manager's VerifiedMarker schema.
        let key = "model.verified.sha.\(spec.managedFilename)"
        let json = "{\"sha\":\"\(sha)\",\"size\":\(size),\"modified\":\(modified)}"
        defaults.set(json, forKey: key)
    }

    private static func modifiedTime(_ url: URL) throws -> Double {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else { return 0 }
        return date.timeIntervalSinceReferenceDate
    }

    // MARK: Utilities

    private enum TestError: LocalizedError {
        case boom
        var errorDescription: String? { "boom" }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: Int = 2000) async {
        for _ in 0..<timeout {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for condition")
    }
}

private extension FakeInstaller {
    /// A stream that yields once then suspends until cancelled, so a pause() /
    /// cancel() can be observed mid-download.
    static func hangingStream() -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ModelInstallProgress(phase: .downloading, downloadedBytes: 1, totalBytes: 100))
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
