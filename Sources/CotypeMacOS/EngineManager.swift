import Foundation
import Combine
import CotypeCore

/// Owns the single, lazily-loaded engine used by the menu app.
///
/// The load is heavy (multi-GB GGUF + Metal context), so it always happens on
/// a dedicated background queue — never on the main thread. SwiftUI observes
/// `status` to drive the loading/ready/error UI in the menu and settings.
///
/// The engine is produced by an injectable `engineFactory`, so the load/unload
/// lifecycle is unit-testable with a mock engine. A pure `EngineLifecycle`
/// tracks the deterministic state (status, cached engine, waiter count, and an
/// invalidation version) so the load/unload race decisions are testable.
public final class EngineManager: ObservableObject, @unchecked Sendable {

    public enum Status: Equatable {
        /// Not loaded and nothing requested yet. Ready to load on demand.
        case idle
        /// A load is in flight.
        case loading
        /// Loaded successfully; the associated value is the model path.
        case ready(String)
        /// Loading failed; the associated value is a user-facing message.
        case failed(String)
    }

    @Published public private(set) var status: Status
    @Published public private(set) var modelPath: String?
    @Published public private(set) var modelSize: Int64?

    private let loadQueue = DispatchQueue(label: "com.cotype.engine.load", qos: .userInitiated)
    private var engineLifecycle = EngineLifecycle()
    private var engine: (any EngineClosable)?
    /// The model path the current `engine` was loaded for, so a changed
    /// `activeModelPath` never hands out a stale engine (refresh old-path gap).
    private var loadedPath: String?

    /// The queue-owned model path used by every load decision. `modelPath` is the
    /// main-actor mirror for the UI; loading reads this queue-owned copy so a
    /// main-thread write to `modelPath` can never race with a loadQueue read.
    private var activeModelPath: String?

    /// A maintenance request (unload / refresh) made while a generation was
    /// streaming. Applied once the last in-flight generation ends, so an engine
    /// is never closed out from under an active stream.
    private var pendingMaintenance: MaintenanceRequest?

    private enum MaintenanceRequest {
        case unload
        case refresh
    }

    /// Produces a new engine for a given model path. Injected so tests can
    /// substitute a mock; the default builds a real `LlamaCppEngine`.
    private let engineFactory: (String) throws -> any EngineClosable

    /// Authoritative size + SHA-256 checker. The production load path verifies
    /// the model off the main actor BEFORE constructing the engine, and never
    /// calls the factory on a mismatch. Injected so tests/custom models can
    /// supply their own expected size + SHA (or a stub).
    private let verifier: any ModelVerifying

    /// Serializes llama.cpp inference so two generations never touch the shared
    /// context at the same time. A second generation WAITS for the slot instead of
    /// being rejected, so a superseding trigger during teardown does not error.
    private let generationLock = NSLock()
    private var generationActive = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    public static let noModelMessage = "No model installed in ~/Library/Application Support/Cotype/Models"

    public init(
        modelPathOverride: String? = nil,
        verifier: any ModelVerifying = ModelIntegrityVerifier(
            expectedSize: ModelSpec.gemma4E2BIt.expectedSize,
            expectedSHA256: ModelSpec.gemma4E2BIt.expectedSHA256
        ),
        engineFactory: @escaping (String) throws -> any EngineClosable = { path in
            let defaults = UserDefaults.standard
            let maxTokens = Int32(defaults.object(forKey: "maxTokens") as? Int ?? 64)
            let temperature = Float(defaults.object(forKey: "temperature") as? Double ?? 0.0)
            return try LlamaCppEngine(path: path, maxTokens: maxTokens, temperature: temperature)
        }
    ) {
        self.engineFactory = engineFactory
        self.verifier = verifier
        let path = modelPathOverride ?? LlamaCppEngine.defaultModelPath()
        modelPath = path
        activeModelPath = path
        modelSize = path.flatMap(Self.fileSize(path:))
        if path == nil {
            engineLifecycle.noModel()
            status = .failed(Self.noModelMessage)
        } else {
            status = .idle
        }
    }

    /// Refreshes the lightweight model metadata after install or removal. Hash
    /// verification belongs to ModelDownloadManager and never runs here.
    @MainActor
    public func refreshModelInfo() {
        refreshToPath(LlamaCppEngine.defaultModelPath())
    }

    /// Update the active model path and reconcile the engine. Internal seam used by
    /// `refreshModelInfo` and by tests, so a concrete path can be driven without
    /// reading the (non-injectable, environment-dependent) default model path.
    func refreshToPath(_ path: String?) {
        modelPath = path
        modelSize = path.flatMap(Self.fileSize(path:))
        // Mirror the path into the queue before any subsequent load reads it, so a
        // concurrent ensureLoaded/loadIfNeeded sees a consistent queue-owned path.
        loadQueue.sync { [weak self] in self?.activeModelPath = path }
        loadQueue.async { [weak self] in self?.applyModelInfoIfIdle() }
    }

    /// Close/replace the engine to match the current model info, but only when it
    /// is safe. If a generation is streaming, defer (a refresh requested during
    /// generation is applied, not dropped, once the last stream ends).
    private func applyModelInfoIfIdle() {
        if isBusy {
            pendingMaintenance = .refresh
            return
        }
        applyModelInfoCore()
    }

    private func applyModelInfoCore() {
        let path = activeModelPath
        // If the cached engine is for a different path (or no model anymore), it is
        // stale and must be closed so a later ensureLoaded loads the new path.
        if engine != nil, loadedPath != path {
            engine?.close()
            engine = nil
            loadedPath = nil
        }
        if path == nil {
            _ = engineLifecycle.unload(allow: true)
            engineLifecycle.noModel()
            engine?.close()
            engine = nil
            loadedPath = nil
            setStatus(.failed(Self.noModelMessage))
            flushWaiters(.failure(EngineError.noModel))
        } else if engine == nil, engineLifecycle.status != .loading {
            _ = engineLifecycle.unload(allow: true)
            setStatus(.idle)
        }
    }

    // MARK: - Public API

    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    public var isBusy: Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generationActive
    }

    /// Kick off a load if one is not already running and no engine is cached.
    public func loadIfNeeded() {
        loadQueue.async { [weak self] in self?.beginLoadIfNeeded() }
    }

    /// Free the model and reset to idle. Refuses to run while a generation is
    /// in flight (the controller only exposes this when idle). Invalidates any
    /// in-flight load/waiter so nothing streams against a freed engine.
    public func unload() {
        loadQueue.async { [weak self] in
            guard let self else { return }
            // Never close an engine out from under an active stream; defer the
            // close until the last generation ends (applied, not dropped).
            guard !self.isBusy else {
                self.pendingMaintenance = .unload
                return
            }
            let allowed = self.engineLifecycle.unload(allow: true)
            guard allowed else { return }
            self.engine?.close()
            self.engine = nil
            self.loadedPath = nil
            self.setStatus(.idle)
            self.flushWaiters(.failure(EngineError.unloaded))
        }
    }

    // MARK: - Engine loading (serialized on loadQueue)

    /// Decide whether to start a load. MUST run on the serial `loadQueue`; this is
    /// the only place that claims a load. The integrity hash runs off the queue
    /// and its outcome is dispatched back here with a version token, so all
    /// `engineLifecycle` / `engine` / waiter mutations stay serialized.
    private func beginLoadIfNeeded() {
        guard let path = activeModelPath else {
            engineLifecycle.noModel()
            setStatus(.failed(Self.noModelMessage))
            flushWaiters(.failure(EngineError.noModel))
            return
        }
        // If an engine is cached or a load is already in flight, do nothing. This
        // coalesces concurrent `loadIfNeeded` / `ensureLoaded` calls to a single
        // verification + factory call.
        guard engineLifecycle.beginLoad() else { return }
        let version = engineLifecycle.loadVersion
        launchVerification(path: path, version: version)
    }

    /// Hash off the main actor AND off the `loadQueue`, then dispatch the outcome
    /// back onto the serial queue with the captured version token. An unload that
    /// happens while hashing bumps `loadVersion`, so the dispatched `finishLoad`
    /// becomes stale and is discarded — the factory is never called and no state
    /// is mutated.
    private func launchVerification(path: String, version: Int) {
        Task.detached(priority: .userInitiated) { [weak self, verifier] in
            let status = await verifier.verify(URL(fileURLWithPath: path))
            self?.loadQueue.async { [weak self] in
                self?.finishLoad(version: version, path: path, status: status)
            }
        }
    }

    /// Complete a load on the serial `loadQueue`. A stale version token (an unload
    /// happened during hashing) aborts the load without touching the factory.
    private func finishLoad(version: Int, path: String, status: ModelVerificationStatus) {
        guard !engineLifecycle.isStale(version) else {
            // An unload already cleared waiters and freed the engine; nothing to do.
            return
        }

        // The integrity hash is authoritative: the factory is never called on a
        // mismatch (this is what prevents a same-size/same-mtime tampered file
        // from ever being constructed, even with a stale marker).
        guard status == .verified else {
            engineLifecycle.finishLoad(success: false)
            let message = Self.verificationErrorMessage(status)
            engine = nil
            loadedPath = nil
            setStatus(.failed(message))
            flushWaiters(.failure(EngineError.corruptModel(message)))
            return
        }

        let result: Result<any EngineClosable, Error>
        do {
            result = .success(try engineFactory(path))
        } catch {
            result = .failure(error)
        }

        engineLifecycle.finishLoad(success: result.isSuccess)
        switch result {
        case .success(let loaded):
            engine = loaded
            loadedPath = path
            setStatus(.ready(path))
        case .failure(let error):
            engine = nil
            loadedPath = nil
            setStatus(.failed(error.localizedDescription))
        }
        flushWaiters(result)
    }

    private func flushWaiters(_ result: Result<any EngineClosable, Error>) {
        let waiters = pendingWaiters
        pendingWaiters = []
        engineLifecycle.setWaiters(0)
        for waiter in waiters { waiter(result) }
    }

    private func setStatus(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.status = status }
    }

    /// Awaits the single-generation slot, claiming it when free. Never rejects;
    /// when a generation is already streaming it queues the caller and resumes
    /// it as soon as the current one finishes or is cancelled.
    private func acquireGenerationSlot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            generationLock.lock()
            if !generationActive {
                generationActive = true
                generationLock.unlock()
                continuation.resume()
            } else {
                generationWaiters.append(continuation)
                generationLock.unlock()
            }
        }
    }

    /// Release the generation slot. The slot is NOT freed here: it stays logically
    /// occupied (a new stream therefore queues, and a concurrent unload/refresh
    /// still defers) until the loadQueue cleanup ran, so deferred maintenance can
    /// never close an engine out from under a freshly-acquired generation. The
    /// actual free/handoff happens in `afterGenerationEnd` on the loadQueue.
    private func releaseGenerationSlot(_ used: (any EngineClosable)?) {
        loadQueue.async { [weak self] in
            self?.afterGenerationEnd(usedEngine: used)
        }
    }

    private func afterGenerationEnd(usedEngine: (any EngineClosable)?) {
        // First retire the engine this generation finished with (if it was replaced
        // by a load while streaming), then apply any deferred maintenance. No stream
        // holds the engine at this instant (the old generation ended; new ones are
        // queued waiting for the slot), so closing is safe.
        retireEngineIfNeeded(usedEngine)
        applyPendingMaintenance()
        dispatchSlot()
    }

    private func retireEngineIfNeeded(_ used: (any EngineClosable)?) {
        guard let used else { return }
        if used !== engine {
            // The engine that generation used is no longer the cached one.
            used.close()
        }
    }

    /// Hand the slot to exactly one waiter (making it active) or mark it inactive
    /// when none are waiting. Any acquisition that arrived during the cleanup
    /// window was queued and is resumed here after deferred maintenance applied, so
    /// it reloads (or reuses) a fresh engine rather than a closed one.
    private func dispatchSlot() {
        var resumeNext: CheckedContinuation<Void, Never>?
        generationLock.lock()
        if !generationWaiters.isEmpty {
            let next = generationWaiters.removeFirst()
            generationActive = true
            resumeNext = next
        } else {
            generationActive = false
            generationWaiters = []
        }
        generationLock.unlock()
        resumeNext?.resume()
    }

    private func applyPendingMaintenance() {
        guard let pending = pendingMaintenance else { return }
        pendingMaintenance = nil
        switch pending {
        case .unload:
            _ = engineLifecycle.unload(allow: true)
            engine?.close()
            engine = nil
            loadedPath = nil
            setStatus(.idle)
            flushWaiters(.failure(EngineError.unloaded))
        case .refresh:
            applyModelInfoCore()
        }
    }

    private static func fileSize(path: String) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Awaiting the engine

    private var pendingWaiters: [(Result<any EngineClosable, Error>) -> Void] = []

    private func ensureLoaded() async throws -> (any EngineClosable, Int) {
        // ONE queue-owned snapshot of engine + loaded path + active path + lifecycle
        // version, taken atomically on the serial loadQueue. No lifecycle/path read
        // happens off the queue, so a concurrent unload or refresh cannot be
        // observed as a torn state.
        let snapshot = loadQueue.sync {
            (engine: self.engine, loadedPath: self.loadedPath, activePath: self.activeModelPath, version: self.engineLifecycle.loadVersion)
        }
        // Only return a cached engine that was loaded for the CURRENT active path;
        // a refresh that changed the path must never hand out the old-path engine.
        if let existing = snapshot.engine, snapshot.loadedPath == snapshot.activePath {
            return (existing, snapshot.version)
        }
        guard snapshot.activePath != nil else {
            throw EngineError.noModel
        }

        return try await withCheckedThrowingContinuation { continuation in
            loadQueue.async {
                // Re-check after hopping onto the queue (the fast path may have
                // raced with an unload between the sync and this async hop).
                if let existing = self.engine {
                    continuation.resume(returning: (existing, self.engineLifecycle.loadVersion))
                    return
                }
                // Capture the version before waiting so a subsequent unload can
                // invalidate this waiter.
                let version = self.engineLifecycle.loadVersion
                self.engineLifecycle.addWaiter()
                self.pendingWaiters.append { result in
                    switch result {
                    case .success(let loaded):
                        continuation.resume(returning: (loaded, version))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                // Begin the load on the serial queue (idempotent: no-op if one is
                // already in flight, so concurrent callers coalesce to one load).
                self.beginLoadIfNeeded()
            }
        }
    }

    private static func verificationErrorMessage(_ status: ModelVerificationStatus) -> String {
        switch status {
        case .verified:
            return "Model verified."
        case .missing:
            return "The model file is missing. Install it in Cotype Setup."
        case .corrupt(let reason):
            return "The standalone model failed Cotype's pinned verification (\(reason)) and will not be loaded. Use Local Models mode, or install the matching standalone model in Setup."
        case .error(let reason):
            return "The standalone model could not be verified (\(reason)). Use Local Models mode, or reinstall the matching standalone model in Setup."
        }
    }
}

// MARK: - InferenceEngine conformance

extension EngineManager: InferenceEngine {

    public var name: String { "llama.cpp" }

    public func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Acquire the generation slot BEFORE fetching the engine, so
                    // maintenance (unload/refresh) sees a busy generation and defers
                    // closing the engine for the WHOLE duration of this stream. This
                    // closes the gap where an unload could free the engine between
                    // ensureLoaded and slot acquisition.
                    await self.acquireGenerationSlot()
                    var usedEngine: (any EngineClosable)?
                    defer { self.releaseGenerationSlot(usedEngine) }
                    let (engine, version) = try await self.ensureLoaded()
                    usedEngine = engine
                    // An unload happened while we waited — this engine is freed.
                    // Read the lifecycle version on the serial queue (never off-queue).
                    let stale = self.loadQueue.sync { self.engineLifecycle.isStale(version) }
                    guard !stale else {
                        throw EngineError.unloaded
                    }
                    try Task.checkCancellation()
                    for try await event in engine.stream(prompt: prompt) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum EngineError: LocalizedError {
    case noModel
    case unloaded
    case corruptModel(String)
    public var errorDescription: String? {
        switch self {
        case .noModel:
            return "No model installed. Install it in Cotype Setup."
        case .unloaded:
            return "The model was unloaded before the completion could run."
        case .corruptModel(let message):
            return message
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
