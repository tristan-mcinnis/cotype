import Foundation

/// Pure state machine for the completion controller's phase + supersession
/// logic. Extracted so the controller's phases and stale-callback rejection are
/// unit-testable without a model or AppKit.
///
/// A single monotonic `generation` token identifies the live request. Every
/// begin/cancel/accept invalidates earlier generations, so a callback from a
/// superseded request can be rejected via `isCurrent(_:)`.
public struct CompletionFlow: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case generating
        case awaitingAccept
    }

    public private(set) var phase: Phase = .idle
    public private(set) var generation: Int = 0

    public init() {}

    /// Start a new generation (superseding any in-flight/awaiting one). Returns
    /// the token for the new generation.
    @discardableResult
    public mutating func beginGeneration() -> Int {
        generation += 1
        phase = .generating
        return generation
    }

    /// A candidate is fully generated and waits for acceptance.
    public mutating func candidateReady() {
        phase = .awaitingAccept
    }

    /// The generation produced no candidate; return to idle without waiting.
    /// Invalidates the generation so a late callback can never mutate state.
    public mutating func finishWithoutCandidate() {
        generation += 1
        phase = .idle
    }

    /// Cancel the current generation, invalidating it.
    public mutating func cancel() {
        generation += 1
        phase = .idle
    }

    /// Accept the current generation, invalidating it and returning to idle.
    public mutating func accept() {
        generation += 1
        phase = .idle
    }

    /// True when `generationID` is still the live generation (not stale).
    public func isCurrent(_ generationID: Int) -> Bool {
        generation == generationID
    }

    /// True when a generation is in flight or awaits acceptance.
    public var isActive: Bool { phase != .idle }
    public var isGenerating: Bool { phase == .generating }
    public var isAwaitingAccept: Bool { phase == .awaitingAccept }
}
