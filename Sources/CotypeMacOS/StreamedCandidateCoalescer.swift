import Foundation
import AppKit
import Combine
import CotypeCore

/// Coalesces a burst of streamed candidate callbacks into at most one pending
/// delivery per run-loop turn.
///
/// The engine streams tokens from a background task while the controller renders
/// on the main actor. Every `submit` stores the newest candidate and schedules a
/// single drain; interleaved tokens in the same turn collapse to the newest one,
/// so the main actor performs at most one update per run-loop turn and the AX
/// focus read stays out of the per-token path.
///
/// `submit` is called from the pipeline's executor and `drain` from the scheduled
/// lane, so all mutable state is guarded by `lock` — which is the whole reason
/// for the `@unchecked Sendable` conformance.
final class StreamedCandidateCoalescer: @unchecked Sendable {
    struct Pending: Equatable {
        var text: String
        var generationID: Int
    }

    /// Runs the scheduled drain. Injected so tests can drain deterministically.
    typealias Scheduler = (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var pending: Pending?
    private var scheduled = false
    private let schedule: Scheduler
    private let deliver: (Pending) -> Void

    init(
        schedule: @escaping Scheduler = { DispatchQueue.main.async(execute: $0) },
        deliver: @escaping (Pending) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// Store the newest candidate and schedule one drain if none is pending.
    func submit(_ text: String, generationID: Int) {
        lock.lock()
        pending = Pending(text: text, generationID: generationID)
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        schedule { [weak self] in self?.drain() }
    }

    /// Deliver the newest pending candidate, if any.
    func drain() {
        lock.lock()
        scheduled = false
        let item = pending
        pending = nil
        lock.unlock()

        guard let item else { return }
        deliver(item)
    }
}
