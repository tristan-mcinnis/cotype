import Foundation
import AppKit
import CotypeCore
import HouseDesign

/// How long the renderer keeps asking for caret geometry after a miss before it
/// gives up. Electron editors often publish the caret a moment after the key
/// that moved it, so one nil is not yet a failure. The total stays well under
/// the point where a late ghost would feel wrong.
public struct CaretRetryPlan: Equatable, Sendable {
    /// Seconds to wait before each further attempt after the first.
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval]) {
        self.delays = delays
    }

    public static let standard = CaretRetryPlan(delays: [0.03, 0.06, 0.12])
    public static let none = CaretRetryPlan(delays: [])
}

/// A transparent, non-activating, inline ghost-text overlay.
///
/// This is the Cotypist-style completion renderer: the candidate is drawn as dim
/// gray text **inline at the editor's AX caret**, on whatever line the caret sits,
/// using the same font/baseline the editor exposes. It never uses a separate
/// popup box, never shows a background, border, or shadow, and never anchors to
/// the mouse.
///
/// Geometry is delegated to the pure `InlineGhostLayout`, which wraps/clips the
/// candidate within the focused field and is fully unit-testable. The window:
/// - is `.borderless`, `.floating`, and ignores mouse events so the editor keeps
///   focus,
/// - is transparent (`isOpaque = false`, clear background, `hasShadow = false`),
/// - only appears when the caret rect and field bounds resolve from AX; if they
///   cannot (laggy web/Electron editors), it retries briefly (`CaretRetryPlan`),
///   keeping an already visible ghost up meanwhile, and then hides rather than
///   guessing.
///
/// When an editor exposes text + selection but NOT caret geometry (e.g. Ghostty —
/// AXTextArea with a readable AXValue/selection but no `kAXBoundsForRange`), there
/// is no correct place to draw the ghost. The renderer then fails closed and
/// hides, unless the user opted into the anchored fallback preview: a suggestion
/// is never shown as a pane, and it never anchors to the mouse.
///
/// All AppKit work is hopped onto the main thread because the pipeline may call
/// `present`/`clear` from a background executor.
public final class GhostTextRenderer: CompletionRenderer {

    /// Inline ghost text is unchanged by design: the editor's own font, no box.
    /// Only its alpha is a token — ink at 42 %.
    public static let ghostAlpha: CGFloat = 0.42
    /// Explicit opt-in for the anchored fallback preview when caret geometry is
    /// unavailable. Off by default: the normal promise is "inline at the caret
    /// or nothing".
    public static let fallbackPreviewKey = "context.fallbackPreview"

    let window: NSWindow
    let ghostContent: GhostContentView
    private let geometryProvider: InlineCaretGeometryProvider?
    private let maxLines: Int
    /// Read at draw time so a Settings toggle applies to the next suggestion.
    private let fallbackEnabled: () -> Bool
    private let caretRetry: CaretRetryPlan
    private let retryScheduler: (TimeInterval, @escaping () -> Void) -> Void
    private let redrawScheduler: (@escaping () -> Void) -> Void

    /// True when the visible ghost is the anchored fallback (no caret position).
    /// Exposed for tests and for the accessibility description.
    public private(set) var isFallbackPreview = false

    public init(
        geometryProvider: InlineCaretGeometryProvider? = AXCaretGeometryProvider(),
        maxLines: Int = 3,
        fallbackEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: GhostTextRenderer.fallbackPreviewKey) as? Bool ?? false
        },
        caretRetry: CaretRetryPlan = .standard,
        retryScheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        redrawScheduler: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.geometryProvider = geometryProvider
        self.maxLines = maxLines
        self.fallbackEnabled = fallbackEnabled
        // With no provider the caret can never resolve, so waiting only delays the verdict.
        self.caretRetry = geometryProvider == nil ? .none : caretRetry
        self.retryScheduler = retryScheduler
        self.redrawScheduler = redrawScheduler
        ghostContent = GhostContentView()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Non-activating, transparent, borderless: the ghost text must never steal
        // focus from the editor nor draw a visible box around itself.
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        window.contentView = ghostContent

        // Accessibility semantics: expose the ghost as an inert completion preview.
        ghostContent.setAccessibilityElement(true)
        ghostContent.setAccessibilityRole(.staticText)
        ghostContent.setAccessibilityLabel("Completion preview")
        ghostContent.setAccessibilityHelp("The completion Cotype would insert with the accept key.")
    }

    /// Coalesced pending work: the LATEST action wins. `.show(String)` draws the
    /// given candidate; `.hide` clears. A single drain applies whichever is the
    /// newest, so interleaving present/clear/present before the drain never drops
    /// the newest show (and never leaves a stale orderOut after a newer show).
    private enum PendingAction {
        case show(String)
        case hide
    }

    public func present(_ candidate: String, for request: CompletionRequest) {
        setPending(.show(candidate))
    }

    /// Render-time guard, checked in `drainRedraw` immediately before geometry
    /// and show. The controller sets it to revalidate that the generation and
    /// focus are still current; if it returns false the overlay fails closed
    /// (`orderOut`) rather than drawing a stale ghost at a moved caret.
    /// Run on the main thread. A nil guard allows the draw (nothing to validate).
    public var renderGuard: (@MainActor () -> Bool)?

    /// Whether the overlay window is currently visible. Exposed for tests.
    public var isShowing: Bool { window.isVisible }

    /// Reports the renderer's real visibility after a deferred draw/hide has
    /// reached AppKit. The controller uses this instead of equating "candidate
    /// generated" with "suggestion shown" in usage metrics.
    public var onVisibilityChanged: (@MainActor (Bool) -> Void)?

    /// Reports why a requested draw ended without a visible ghost: no caret
    /// geometry, or a ghost that does not fit the field. Run on the main thread.
    public var onNotShown: (@MainActor (NotShownReason) -> Void)?

    public func clear() {
        setPending(.hide)
    }

    // MARK: - Coalesced redraw

    private let stateLock = NSLock()
    private var pendingAction: PendingAction?
    private var redrawScheduled = false
    /// Bumped by every present/clear. A caret retry carries the value it was
    /// started under and drops itself when a newer request has superseded it.
    private var generation = 0

    private func setPending(_ action: PendingAction) {
        // Coalesce per-token updates into at most one redraw per main-runloop
        // turn. Protect this state because engines stream from a worker task
        // while AppKit drains redraws on the main thread.
        stateLock.lock()
        pendingAction = action
        generation &+= 1
        let shouldSchedule = !redrawScheduled
        if shouldSchedule { redrawScheduled = true }
        stateLock.unlock()

        guard shouldSchedule else { return }
        redrawScheduler { [weak self] in
            self?.drainRedraw()
        }
    }

    private func drainRedraw() {
        stateLock.lock()
        redrawScheduled = false
        let action = pendingAction
        let drainedGeneration = generation
        pendingAction = nil
        stateLock.unlock()

        switch action {
        case .show(let candidate):
            attemptShow(candidate, generation: drainedGeneration, remainingDelays: caretRetry.delays[...])
        case .hide, .none:
            hideWindow()
            MainActor.assumeIsolated { onVisibilityChanged?(false) }
        }
    }

    /// One draw attempt for a pending show. A caret miss schedules the next
    /// attempt; only the last attempt may give up and report `noCaretGeometry`.
    private func attemptShow(_ candidate: String, generation: Int, remainingDelays: ArraySlice<TimeInterval>) {
        // Fail closed at the last instant: if the generation/focus no longer
        // matches, do not draw a stale ghost (a focus change could have
        // happened between scheduling and this drain on the main queue).
        guard MainActor.assumeIsolated({ renderGuard?() ?? true }) else {
            hideWindow()
            MainActor.assumeIsolated { onVisibilityChanged?(false) }
            return
        }
        let geometry = geometryProvider?.caretGeometry()
        if let geometry {
            showInline(candidate: candidate, geometry: geometry)
        } else {
            handleCaretMiss(candidate, isFinal: remainingDelays.isEmpty)
        }
        MainActor.assumeIsolated { onVisibilityChanged?(window.isVisible) }
        guard geometry == nil, let delay = remainingDelays.first else { return }
        retryScheduler(delay) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.attemptShow(candidate, generation: generation, remainingDelays: remainingDelays.dropFirst())
        }
    }

    /// The opt-in fallback is drawn at once, so a terminal that never reports a
    /// caret keeps a visible (and acceptable) preview while retries run. Without
    /// it, a window on screen still shows the previous candidate, and reporting
    /// it visible would let the accept key insert text the user never saw, so it
    /// hides until a retry draws the current candidate. Only the final miss
    /// reports why nothing is shown.
    private func handleCaretMiss(_ candidate: String, isFinal: Bool) {
        let field = fallbackEnabled() ? (geometryProvider as? InlineFieldGeometryProvider)?.fieldGeometry() : nil
        if let field, showFallback(candidate: candidate, field: field) { return }
        guard isFinal else {
            hideWindow()
            return
        }
        let reason: NotShownReason = field == nil ? .noCaretGeometry : .ghostDoesNotFit
        CotypeLog.geometry.info("hide: \(field == nil ? "no usable caret geometry" : "fallback ghost does not fit the field", privacy: .public)")
        MainActor.assumeIsolated { onNotShown?(reason) }
        hideWindow()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return self.generation == generation
    }

    /// Order the overlay out only when it is actually on screen.
    private func hideWindow() {
        isFallbackPreview = false
        guard window.isVisible else { return }
        window.orderOut(nil)
    }

    // MARK: - Main-thread UI

    /// Draw the candidate at a fixed anchor inside the focused field: the
    /// bottom-left of the field's real AX frame. Clearly inside the field the
    /// text will land in, never at the mouse, never in a detached pane. One line,
    /// clipped by the same layout rules as the inline ghost. Returns false, with
    /// the window untouched, when one line does not fit.
    private func showFallback(candidate: String, field: CaretFieldGeometry) -> Bool {
        let metrics = field.metrics
        let lineHeight = max(metrics.lineHeight, 1)
        // Fail closed when the field cannot contain one line plus the 2 pt inset:
        // anchoring at the bottom would otherwise draw above the field.
        guard field.fieldBounds.height >= lineHeight + 4,
              field.fieldBounds.width > 4 else { return false }
        let anchor = CGRect(
            x: field.fieldBounds.minX + 2,
            y: field.fieldBounds.maxY - lineHeight - 2,
            width: 0,
            height: lineHeight
        )
        let measure: (String) -> CGFloat = { text in
            (text as NSString).size(withAttributes: [.font: metrics.font]).width
        }
        let layout = InlineGhostLayout.layout(
            caretRect: anchor,
            fieldBounds: field.fieldBounds,
            metrics: metrics,
            maxLines: 1,
            candidate: candidate,
            measure: measure
        )
        guard !layout.lines.isEmpty else { return false }

        if window.contentView !== ghostContent {
            window.contentView = ghostContent
        }
        ghostContent.lines = layout.lines.map { ($0.text, $0.xOffset) }
        ghostContent.metrics = metrics
        ghostContent.textColor = field.textColor
        ghostContent.setAccessibilityValue(candidate)
        ghostContent.setAccessibilityHelp("Anchored completion preview: no caret position was available; Cotype will insert this at the caret.")
        ghostContent.needsDisplay = true
        isFallbackPreview = true

        let appKitOrigin = CaretPlacement.toAppKitWindowOrigin(
            axTopLeft: layout.origin,
            size: layout.size,
            primaryScreenHeight: primaryScreenHeight()
        )
        applyOverlayFrame(NSRect(origin: appKitOrigin, size: layout.size))
        return true
    }

    /// Draw the candidate as inline ghost text at the exact AX caret geometry.
    private func showInline(candidate: String, geometry: CaretGeometry) {
        let metrics = geometry.metrics
        let measure: (String) -> CGFloat = { text in
            (text as NSString).size(withAttributes: [.font: metrics.font]).width
        }

        let layout = InlineGhostLayout.layout(
            caretRect: geometry.caretRect,
            fieldBounds: geometry.fieldBounds,
            metrics: metrics,
            maxLines: maxLines,
            textInset: geometry.textInset,
            candidate: candidate,
            measure: measure
        )

        guard !layout.lines.isEmpty else {
            CotypeLog.geometry.info("hide: ghost does not fit the field at the caret")
            MainActor.assumeIsolated { onNotShown?(.ghostDoesNotFit) }
            hideWindow()
            return
        }

        if window.contentView !== ghostContent {
            window.contentView = ghostContent
        }
        ghostContent.lines = layout.lines.map { ($0.text, $0.xOffset) }
        ghostContent.metrics = metrics
        ghostContent.textColor = geometry.textColor
        ghostContent.setAccessibilityValue(candidate)
        ghostContent.setAccessibilityHelp("The completion Cotype would insert with the accept key.")
        ghostContent.needsDisplay = true
        isFallbackPreview = false

        // Convert the block's AX top-left origin to an AppKit window origin.
        let appKitOrigin = CaretPlacement.toAppKitWindowOrigin(
            axTopLeft: layout.origin,
            size: layout.size,
            primaryScreenHeight: primaryScreenHeight()
        )
        applyOverlayFrame(NSRect(origin: appKitOrigin, size: layout.size))
    }

    /// Apply the overlay frame and bring the window forward, skipping both AppKit
    /// calls when they would be redundant: the ghost shrinks or swaps content on
    /// every streamed update, and re-`setFrame` + `orderFrontRegardless` each time
    /// is wasted work that can flicker. A changed frame or a hidden window still
    /// applies normally.
    private func applyOverlayFrame(_ rect: NSRect) {
        if !NSEqualRects(window.frame, rect) {
            window.setFrame(rect, display: false)
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }
}

// MARK: - Ghost content view

/// Draws the (pre-wrapped) ghost lines with the resolved editor font, so the text
/// sits inline at the caret line. Flipped so its coordinate space matches the AX
/// y-down geometry produced by `InlineGhostLayout`, and so `draw(at:)` maps the
/// top-left corner without an extra flip.
final class GhostContentView: NSView {
    var lines: [(text: String, xOffset: CGFloat)] = []
    var metrics: GhostTextMetrics = .default
    /// The host's own text colour; nil draws with the design token.
    var textColor: NSColor?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .copy
            NSColor.clear.setFill()
            dirtyRect.fill()
            context.restoreGraphicsState()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: metrics.font,
            .foregroundColor: (textColor ?? House.NSColorToken.textPrimary)
                .withAlphaComponent(GhostTextRenderer.ghostAlpha),
            .paragraphStyle: clippingParagraphStyle,
        ]
        for (index, line) in lines.enumerated() {
            // Each line box is one line height tall. The baseline inside it comes
            // from the resolved metrics, not from the draw point, so a ghost fitted
            // to the editor's own line box lands on the editor's baseline.
            let point = NSPoint(
                x: line.xOffset,
                y: CGFloat(index) * metrics.lineHeight + metrics.baselineDrawOffset
            )
            NSString(string: line.text).draw(at: point, withAttributes: attrs)
        }
    }

    private var clippingParagraphStyle: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        // Lay each pre-wrapped line out as a single run and clip it: wrapping is
        // computed by the pure geometry, so the field clips any leftover width.
        style.lineBreakMode = .byClipping
        return style
    }
}
