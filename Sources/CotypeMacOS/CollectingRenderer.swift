import Foundation
import AppKit
import Combine
import CotypeCore

/// Collects the streaming candidate and forwards it to the controller for
/// validation (`onCandidate`), but **does not render**. Rendering is driven by
/// the controller via `setGhost` only after it has confirmed this generation is
/// still current and the focus target still matches — a stale streamed token can
/// never be drawn before validation.
final class CollectingRenderer: CompletionRenderer {
    var onCandidate: ((String) -> Void)?

    /// The underlying renderer. Injected so tests can spy on renders; production
    /// uses the ghost-text overlay.
    private let inner: CompletionRenderer

    init(inner: CompletionRenderer = GhostTextRenderer()) {
        self.inner = inner
    }

    func present(_ candidate: String, for request: CompletionRequest) {
        // Only collect/callback. The controller may render after validation.
        onCandidate?(candidate)
    }

    func clear() {
        inner.clear()
        if !(inner is GhostTextRenderer) {
            fallbackShowing = false
            // Pipeline stages may clear from a background executor; a simple
            // renderer's report must hop to main rather than assume isolation.
            let report = fallbackVisibility
            if Thread.isMainThread {
                MainActor.assumeIsolated { report?(false) }
            } else {
                DispatchQueue.main.async { report?(false) }
            }
        }
    }

    /// Update the ghost overlay without re-triggering the candidate callback.
    /// Used when the interaction loop shrinks/clears the ghost via type-through
    /// or accept — after the controller has validated generation + focus. The
    /// `CompletionRequest` is vestigial for positioning.
    func setGhost(_ candidate: String) {
        inner.present(candidate, for: CompletionRequest())
        if !(inner is GhostTextRenderer) {
            fallbackShowing = !candidate.isEmpty
            let report = fallbackVisibility
            if Thread.isMainThread {
                MainActor.assumeIsolated { report?(fallbackShowing) }
            } else {
                let showing = fallbackShowing
                DispatchQueue.main.async { report?(showing) }
            }
        }
    }

    /// Forward the render-time guard to the underlying ghost renderer.
    var renderGuard: (@MainActor () -> Bool)? {
        get { (inner as? GhostTextRenderer)?.renderGuard }
        set { (inner as? GhostTextRenderer)?.renderGuard = newValue }
    }

    var onNotShown: (@MainActor (NotShownReason) -> Void)? {
        get { (inner as? GhostTextRenderer)?.onNotShown }
        set { (inner as? GhostTextRenderer)?.onNotShown = newValue }
    }

    /// Visibility reports. The production overlay reports its real post-AppKit
    /// visibility. A test renderer that cannot report is treated as showing what
    /// it was told to draw, so the controller's visible-preview invariant stays
    /// testable without a window.
    private var fallbackVisibility: (@MainActor (Bool) -> Void)?
    private var fallbackShowing = false

    var onVisibilityChanged: (@MainActor (Bool) -> Void)? {
        get {
            if let ghost = inner as? GhostTextRenderer { return ghost.onVisibilityChanged }
            return fallbackVisibility
        }
        set {
            if let ghost = inner as? GhostTextRenderer {
                ghost.onVisibilityChanged = newValue
            } else {
                fallbackVisibility = newValue
            }
        }
    }

    /// Whether the underlying ghost overlay is showing. Exposed for tests.
    var isShowing: Bool {
        if let ghost = inner as? GhostTextRenderer { return ghost.isShowing }
        return fallbackShowing
    }

    /// Whether this renderer reports real visibility. The production overlay
    /// does; a simple test renderer does not.
    var reportsVisibility: Bool { inner is GhostTextRenderer }
}
