import Foundation

/// Pure state machine for `EngineManager`'s load/unload/waiter decisions.
///
/// The manager owns the async work; this type owns the *deterministic* bookkeeping
/// (status, whether an engine is cached, an invalidation version, and the waiter
/// count) so the load/unload race decisions are unit-testable without a model.
public struct EngineLifecycle: Equatable, Sendable {

    public enum Status: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed
    }

    public private(set) var status: Status = .idle
    /// True when a usable engine is cached (so a load is a no-op).
    public private(set) var hasLoadedEngine = false
    /// Bumped on every unload. A load/waiter that captured an older version is
    /// stale and must not stream against a freed engine.
    public private(set) var loadVersion = 0
    /// How many callers are waiting for an engine to become available.
    public private(set) var waiterCount = 0

    public init() {}

    /// Begin a load. Returns true if a load should actually run (no cached engine
    /// and not already loading); false if it is a no-op or already running.
    @discardableResult
    public mutating func beginLoad() -> Bool {
        if hasLoadedEngine || status == .loading { return false }
        status = .loading
        return true
    }

    /// A load completed.
    public mutating func finishLoad(success: Bool) {
        status = success ? .ready : .failed
        hasLoadedEngine = success
    }

    /// Attempt to unload. Refuses when a generation is active. On success,
    /// invalidates in-flight loads/waiters and returns to idle.
    @discardableResult
    public mutating func unload(allow: Bool) -> Bool {
        guard allow else { return false }
        loadVersion += 1
        status = .idle
        hasLoadedEngine = false
        waiterCount = 0
        return true
    }

    public mutating func addWaiter() {
        waiterCount += 1
    }

    public mutating func removeWaiter() {
        waiterCount = max(0, waiterCount - 1)
    }

    public mutating func setWaiters(_ count: Int) {
        waiterCount = max(0, count)
    }

    /// True when a load/waiter that captured this `loadVersion` is now stale
    /// (an unload happened since it started).
    public func isStale(_ version: Int) -> Bool {
        version != loadVersion
    }

    /// True when the model path is missing and no engine can ever load.
    public mutating func noModel() {
        status = .failed
        hasLoadedEngine = false
    }
}
