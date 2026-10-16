import XCTest
import CryptoKit
import CotypeCore
@testable import CotypeMacOS

// MARK: - Test double

/// A verifier that always passes, so existing lifecycle tests (which point at a
/// nonexistent `/fake/model.gguf`) are unaffected by the real integrity check.
private struct AlwaysVerified: ModelVerifying {
    var expectedSize: Int64 = 0
    var expectedSHA256: String = ""
    func verify(_ url: URL) async -> ModelVerificationStatus { .verified }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A thread-safe counter.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

/// A verifier that counts calls and can hold the load open for a delay window.
private final class CountingVerifier: ModelVerifying, @unchecked Sendable {
    let expectedSize: Int64
    let expectedSHA256: String
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    init(expectedSize: Int64 = 0, expectedSHA256: String = "", delayNanoseconds: UInt64 = 5_000_000) {
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.delayNanoseconds = delayNanoseconds
    }

    func verify(_ url: URL) async -> ModelVerificationStatus {
        lock.withLock { _calls += 1 }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        return .verified
    }
}

/// A verifier that suspends until `release()`, letting a test hold a load
/// "mid-hash" and exercise the unload-during-verification race deterministically.
private final class GateVerifier: ModelVerifying, @unchecked Sendable {
    let expectedSize: Int64 = 0
    let expectedSHA256: String = ""
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var _started = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }

    func verify(_ url: URL) async -> ModelVerificationStatus {
        await withCheckedContinuation { c in
            lock.lock()
            _started = true
            continuation = c
            lock.unlock()
        }
        return .verified
    }

    func release() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

/// A closable engine whose stream can be held open (generation stays active) until
/// `release()` — lets a test exercise unload/refresh during an active stream, and
/// observe when `close()` happens. Uses a continuation gate (no thread blocking).
private final class GatedClosableEngine: EngineClosable, @unchecked Sendable {
    let name = "gated-closable"
    private let holdGeneration: Bool
    private var _closed = false
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?

    init(holdGeneration: Bool) { self.holdGeneration = holdGeneration }

    var isClosed: Bool { lock.withLock { _closed } }

    func close() {
        lock.withLock { _closed = true }
    }

    func release() {
        lock.withLock { let c = gate; gate = nil; c?.resume() }
    }

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token("hi"))
            if self.holdGeneration {
                let task = Task {
                    await withCheckedContinuation { c in
                        self.lock.withLock { self.gate = c }
                    }
                    continuation.yield(.end)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.yield(.end)
                continuation.finish()
            }
        }
    }
}

// MARK: - EngineManager lifecycle

final class EngineManagerTests: XCTestCase {

    func testLoadVerifiedEngineForgetsThePinButIsIndependentlyIntegrityChecked() async throws {
        // The load path must verify (off-main) BEFORE constructing the engine. A
        // tampered same-size file must never reach the factory, even if a stale
        // size+mtime marker exists elsewhere.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("gemma-4-E2B-it-Q4_K_M.gguf")
        let correct = Data(String(repeating: "a", count: 256).utf8)
        try correct.write(to: path)
        let goodSHA = sha256Hex(correct)

        // Tamper: same byte length, different content (the exact attack a
        // size+mtime marker would NOT catch).
        let tampered = Data(String(repeating: "b", count: 256).utf8)
        XCTAssertEqual(tampered.count, correct.count)
        try tampered.write(to: path)

        var factoryCalls = 0
        let manager = EngineManager(
            modelPathOverride: path.path,
            verifier: ModelIntegrityVerifier(expectedSize: Int64(correct.count), expectedSHA256: goodSHA),
            engineFactory: { _ in
                factoryCalls += 1
                return MockClosableEngine()
            }
        )

        XCTAssertEqual(manager.status, .idle)
        manager.loadIfNeeded()
        let failed = await waitUntil { if case .failed = manager.status { return true } else { return false } }

        XCTAssertTrue(failed, "a tampered model must never be reported loadable")
        XCTAssertEqual(factoryCalls, 0, "the engine factory must NEVER be called on a verification mismatch")
    }


    @MainActor
    func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testLoadIfNeededLoadsAndCachesEngine() async {
        let mock = MockClosableEngine(response: "hi")
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: AlwaysVerified(),
            engineFactory: { _ in mock }
        )
        XCTAssertEqual(manager.status, .idle)
        manager.loadIfNeeded()
        let ready = await waitUntil { manager.isReady }
        XCTAssertTrue(ready)
        XCTAssertFalse(mock.closed)
        // A second load is a no-op (engine already cached).
        manager.loadIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(manager.isReady)
    }

    func testUnloadClosesEngineAndReturnsToIdle() async {
        let mock = MockClosableEngine(response: "hi")
        let manager = EngineManager(modelPathOverride: "/fake/model.gguf", verifier: AlwaysVerified(), engineFactory: { _ in mock })
        manager.loadIfNeeded()
        _ = await waitUntil { manager.isReady }

        manager.unload()
        let idle = await waitUntil { if case .idle = manager.status { return true } else { return false } }
        XCTAssertTrue(idle)
        XCTAssertTrue(mock.closed)
    }

    // MARK: - Concurrency / lifecycle races

    func testConcurrentLoadIfNeededCoalesceToOneFactoryCall() async {
        let verifier = CountingVerifier(delayNanoseconds: 15_000_000)
        let counter = Counter()
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: verifier,
            engineFactory: { _ in counter.increment(); return MockClosableEngine() }
        )

        // Many concurrent load requests must be serialized on the loadQueue so
        // exactly one verification + one factory call happen.
        for _ in 0..<8 { manager.loadIfNeeded() }

        let ready = await waitUntil { manager.isReady }
        XCTAssertTrue(ready, "a load that is claimed must complete")
        XCTAssertEqual(counter.value, 1, "concurrent loadIfNeeded must coalesce to a single factory call")
    }

    func testConcurrentEnsureLoadedCoalesceToOneLoad() async {
        let verifier = CountingVerifier(delayNanoseconds: 15_000_000)
        let counter = Counter()
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: verifier,
            engineFactory: { _ in counter.increment(); return MockClosableEngine(response: "hi") }
        )

        // Two concurrent streams each await the engine; they must coalesce to one
        // load, and BOTH must complete once.
        let tokens = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    var iterator = manager.stream(prompt: Prompt(user: "x")).makeAsyncIterator()
                    guard let event = try? await iterator.next() else { return nil }
                    if case .token(let t) = event { return t }
                    return nil
                }
            }
            var out: [String?] = []
            for await t in group { out.append(t) }
            return out
        }

        XCTAssertEqual(tokens.compactMap { $0 }.count, 2, "both concurrent streams must complete")
        XCTAssertEqual(tokens.filter { $0 == "hi" }.count, 2)
        XCTAssertEqual(counter.value, 1, "concurrent ensureLoaded must coalesce to one factory call")
    }

    // MARK: - Close/use race: unload/refresh must never close a streaming engine

    func testUnloadDuringStreamingDefersClose() async {
        let engine = GatedClosableEngine(holdGeneration: true)
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: AlwaysVerified(),
            engineFactory: { _ in engine }
        )

        var iterator = manager.stream(prompt: Prompt(user: "x")).makeAsyncIterator()
        // Consume the first token: the generation is now active and the slot held.
        guard case .token(let t)? = try? await iterator.next(), t == "hi" else {
            return XCTFail("expected the first token")
        }

        // Unload while the stream is active: it must DEFER, never close the engine
        // out from under the stream (the old gap between ensureLoaded and slot
        // acquisition is closed because the slot is held for the whole stream).
        manager.unload()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(engine.isClosed, "unload during a stream must NOT close the engine")

        // Release the stream; the deferred unload then applies.
        engine.release()
        _ = try? await iterator.next()
        let closed = await waitUntil { engine.isClosed }
        XCTAssertTrue(closed, "deferred unload must close the engine once the stream ends")
    }

    func testRefreshWhileStreamingDefersClose() async {
        let engine = GatedClosableEngine(holdGeneration: true)
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: AlwaysVerified(),
            engineFactory: { _ in engine }
        )

        var iterator = manager.stream(prompt: Prompt(user: "x")).makeAsyncIterator()
        guard case .token? = try? await iterator.next() else {
            return XCTFail("expected the first token")
        }

        // A refresh (path change) requested while a generation is streaming must be
        // deferred, not applied while the engine is in use.
        await MainActor.run { manager.refreshModelInfo() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(engine.isClosed, "refresh during a stream must defer the engine close")

        engine.release()
        _ = try? await iterator.next()
        let closed = await waitUntil { engine.isClosed }
        XCTAssertTrue(closed, "deferred refresh must close the stale engine once the stream ends")
    }

    func testRefreshOldPathLoadsNewEngine() async {
        var engines: [GatedClosableEngine] = []
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: AlwaysVerified(),
            engineFactory: { _ in
                let e = GatedClosableEngine(holdGeneration: false)
                engines.append(e)
                return e
            }
        )

        // Load the old-path engine.
        manager.loadIfNeeded()
        let ready1 = await waitUntil { manager.isReady }
        XCTAssertTrue(ready1)
        XCTAssertEqual(engines.count, 1)
        let engineA = engines[0]

        // Refresh to a DIFFERENT path (no generation busy) -> the old-path engine
        // is closed, and a later load builds a NEW engine for the new path.
        await MainActor.run { manager.refreshToPath("/fake/model-B.gguf") }
        let engineAClosed = await waitUntil { engineA.isClosed }
        XCTAssertTrue(engineAClosed, "the old-path engine must be closed after a path change")

        manager.loadIfNeeded()
        // Wait for the factory to build a NEW engine for the new path.
        let gotNewEngine = await waitUntil { engines.count >= 2 }
        XCTAssertTrue(gotNewEngine, "a new engine must be loaded for the new path")
        XCTAssertTrue(engines[1] !== engineA, "the old-path engine must never be handed out for the new path")
    }

    func testPendingCleanupDoesNotCloseEngineUsedByLaterStream() async {
        var engines: [GatedClosableEngine] = []
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: AlwaysVerified(),
            engineFactory: { _ in
                let e = GatedClosableEngine(holdGeneration: true)
                engines.append(e)
                return e
            }
        )

        // Stream A acquires the slot and uses engines[0].
        var iteratorA = manager.stream(prompt: Prompt(user: "x")).makeAsyncIterator()
        guard case .token? = try? await iteratorA.next() else { return XCTFail("expected A token") }
        XCTAssertEqual(engines.count, 1)
        let engineA = engines[0]

        // Unload requested while A streams -> deferred (the slot stays occupied).
        manager.unload()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertFalse(engineA.isClosed, "unload must defer while a generation is active")

        // Stream B starts while A is still active. It must QUEUE for the slot (the
        // slot is not freed at A's release instant) rather than acquire it before
        // the deferred unload/cleanup runs.
        let bTask = Task { () -> String? in
            var iteratorB = manager.stream(prompt: Prompt(user: "x")).makeAsyncIterator()
            guard case .token(let t)? = try? await iteratorB.next() else { return nil }
            return t
        }
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Release A: its stream ends; the slot stays occupied until the loadQueue
        // cleanup runs the deferred unload, so B can never acquire an engine that is
        // about to be closed.
        engineA.release()
        _ = try? await iteratorA.next()   // consume A's .end

        let bToken = await bTask.value
        XCTAssertEqual(bToken, "hi", "stream B must complete with a token")
        XCTAssertTrue(engineA.isClosed, "the deferred unload must close engine A once its stream ends")
        XCTAssertGreaterThanOrEqual(engines.count, 2, "B must load a fresh engine, not the closed one")
        XCTAssertFalse(engines[1].isClosed, "B's engine must NOT be closed while B references it")

        // Let B finish so its stream/task don't leak past the test.
        engines[1].release()
    }

    func testUnloadDuringVerificationPreventsStaleFactoryLoad() async {
        let verifier = GateVerifier()
        let counter = Counter()
        let manager = EngineManager(
            modelPathOverride: "/fake/model.gguf",
            verifier: verifier,
            engineFactory: { _ in counter.increment(); return MockClosableEngine() }
        )

        manager.loadIfNeeded()
        // Wait until hashing is in progress (verification suspended on the gate).
        _ = await waitUntil { verifier.started }

        // Unload while the hash is still in flight (invalidates the load version).
        manager.unload()
        verifier.release()

        // Give the discarded finishLoad a moment; the factory must never be called
        // and the manager must not be ready.
        _ = await waitUntil { counter.value == 0 }
        XCTAssertEqual(counter.value, 0, "an unload during hashing must discard a stale load — factory never called")
        XCTAssertFalse(manager.isReady)
    }

    func testStreamThrowsWhenNoModel() async {
        let manager = EngineManager(modelPathOverride: nil, engineFactory: { path in
            throw EngineError.noModel
        })
        do {
            var iterator = manager.stream(prompt: Prompt(user: "hi")).makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail("expected stream to throw")
        } catch {
            guard let e = error as? EngineError, case .noModel = e else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

// MARK: - CompletionController phases, stale callbacks, focus guard

@MainActor
final class CompletionControllerTests: XCTestCase {

    private func makeController(
        engine: InferenceEngine,
        frontmostAppProvider: @escaping () -> String? = { "com.example.editor" },
        learnFromFeedback: Bool = true
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeUserDefaults()
        defaults.set(learnFromFeedback, forKey: "learnFromFeedback")
        defaults.set(true, forKey: "enableCompletions")
        let personalization = makePersonalizationStore()
        let overrides = AppOverridesStore(fileURL: tempFileURL("overrides"))
        let inserter = RecordingInserter()
        let controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", verifier: AlwaysVerified(), engineFactory: { _ in MockClosableEngine() }),
            personalization: personalization,
            overrides: overrides,
            inserter: inserter,
            pipelineEngineOverride: engine,
            frontmostAppProvider: frontmostAppProvider,
            focusIdentityProvider: StubFocusIdentityProvider(
                FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 1, selection: .unsupported)
            ),
            userDefaults: defaults
        )
        return (controller, inserter)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testTriggerTransitionsToAwaitingAccept() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0))
        let launched = controller.trigger()
        XCTAssertTrue(launched)
        XCTAssertEqual(controller.phase, .generating)

        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.currentCandidate, "hello")
    }

    func testAcceptInsertsIntoOriginalApp() async {
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" }
        )
        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }

        controller.accept()
        _ = await waitUntil { inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["hello"])
        XCTAssertEqual(inserter.insertedApps, ["com.example.editor"])
    }

    func testTriggerDisabledByApp() {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "x"))
        // Force completions disabled.
        controller.completionsEnabled = false
        XCTAssertFalse(controller.trigger())
        XCTAssertEqual(controller.lastError, "Completions are disabled.")
    }

    func testSupersedingTriggerRejectsStaleCallback() async {
        let scripted = ScriptedEngine(["first candidate", "second candidate"], wordDelayNanoseconds: 20_000_000)
        let (controller, _) = makeController(engine: scripted, frontmostAppProvider: { "com.example.editor" })

        XCTAssertTrue(controller.trigger())   // generation 1 (slow)
        // Wait until generation 1 has actually started its stream (and consumed
        // its scripted response) so supersession is tested, not task ordering.
        let inFlight = await waitUntil { scripted.callsStarted == 1 }
        XCTAssertTrue(inFlight)
        XCTAssertTrue(controller.trigger())   // generation 2 supersedes
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.currentCandidate, "second candidate")
    }

    func testCancelDismissesPending() async {
        let (controller, _) = makeController(engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 20_000_000))
        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)

        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.candidateAvailable)
    }

    func testFocusChangeCancelsPendingCompletionAndNeverInserts() async {
        let (controller, inserter) = makeController(
            engine: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 20_000_000),
            frontmostAppProvider: { "com.example.editor" }
        )
        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)

        // User switches to a different app: pending completion must cancel.
        controller.noteFrontmostAppChanged("com.other.app")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.candidateAvailable)
        // Give any straggling accept task a moment; nothing may be inserted.
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }
}
