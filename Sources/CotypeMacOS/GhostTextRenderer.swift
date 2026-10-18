import Foundation
import AppKit
import CotypeCore
import HouseDesign

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
///   cannot (laggy web/Electron editors), it hides rather than guessing.
///
/// When an editor exposes text + selection but NOT caret geometry (e.g. Ghostty —
/// AXTextArea with a readable AXValue/selection but no `kAXBoundsForRange`), there
/// is no correct place to draw the ghost. The renderer then fails closed and
/// hides: a suggestion that cannot be drawn inline at the caret is never shown as
/// a pane, and it never anchors to the mouse.
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

    /// True when the visible ghost is the anchored fallback (no caret position).
    /// Exposed for tests and for the accessibility description.
    public private(set) var isFallbackPreview = false

    public init(
        geometryProvider: InlineCaretGeometryProvider? = AXCaretGeometryProvider(),
        maxLines: Int = 3,
        fallbackEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: GhostTextRenderer.fallbackPreviewKey) as? Bool ?? false
        }
    ) {
        self.geometryProvider = geometryProvider
        self.maxLines = maxLines
        self.fallbackEnabled = fallbackEnabled
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

    private func setPending(_ action: PendingAction) {
        // Coalesce per-token updates into at most one redraw per main-runloop
        // turn. Protect this state because engines stream from a worker task
        // while AppKit drains redraws on the main thread.
        stateLock.lock()
        pendingAction = action
        let shouldSchedule = !redrawScheduled
        if shouldSchedule { redrawScheduled = true }
        stateLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainRedraw()
        }
    }

    private func drainRedraw() {
        stateLock.lock()
        redrawScheduled = false
        let action = pendingAction
        pendingAction = nil
        stateLock.unlock()

        switch action {
        case .show(let candidate):
            // Fail closed at the last instant: if the generation/focus no longer
            // matches, do not draw a stale ghost (a focus change could have
            // happened between scheduling and this drain on the main queue).
            if MainActor.assumeIsolated({ renderGuard?() ?? true }) {
                show(candidate: candidate)
                MainActor.assumeIsolated { onVisibilityChanged?(window.isVisible) }
            } else {
                hideWindow()
                MainActor.assumeIsolated { onVisibilityChanged?(false) }
            }
        case .hide, .none:
            hideWindow()
            MainActor.assumeIsolated { onVisibilityChanged?(false) }
        }
    }

    /// Order the overlay out only when it is actually on screen.
    private func hideWindow() {
        isFallbackPreview = false
        guard window.isVisible else { return }
        window.orderOut(nil)
    }

    // MARK: - Main-thread UI

    func show(candidate: String) {
        // Inline ghost text at the caret is the only thing Cotype draws by
        // default. When exact caret geometry is unavailable (laggy web/Electron
        // editors, terminals without `kAXBoundsForRange`) there is no correct
        // place to draw, so this fails closed: hide, never show a pane or guess
        // an anchor. The opt-in fallback anchors to the focused field's own
        // bottom-left corner and is still inert, click-through ghost text.
        guard let geometry = geometryProvider?.caretGeometry() else {
            if fallbackEnabled(), let field = (geometryProvider as? InlineFieldGeometryProvider)?.fieldGeometry() {
                showFallback(candidate: candidate, field: field)
                return
            }
            CotypeLog.geometry.info("hide: no usable caret geometry")
            MainActor.assumeIsolated { onNotShown?(.noCaretGeometry) }
            isFallbackPreview = false
            hideWindow()
            return
        }
        isFallbackPreview = false
        showInline(candidate: candidate, geometry: geometry)
    }

    /// Draw the candidate at a fixed anchor inside the focused field: the
    /// bottom-left of the field's real AX frame. Clearly inside the field the
    /// text will land in, never at the mouse, never in a detached pane. One line,
    /// clipped by the same layout rules as the inline ghost.
    private func showFallback(candidate: String, field: CaretFieldGeometry) {
        let metrics = field.metrics
        let lineHeight = max(metrics.lineHeight, 1)
        // Fail closed when the field cannot contain one line plus the 2 pt inset:
        // anchoring at the bottom would otherwise draw above the field.
        guard field.fieldBounds.height >= lineHeight + 4,
              field.fieldBounds.width > 4 else {
            CotypeLog.geometry.info("hide: fallback ghost does not fit the field")
            MainActor.assumeIsolated { onNotShown?(.ghostDoesNotFit) }
            isFallbackPreview = false
            hideWindow()
            return
        }
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
        guard !layout.lines.isEmpty else {
            CotypeLog.geometry.info("hide: fallback ghost does not fit the field")
            MainActor.assumeIsolated { onNotShown?(.ghostDoesNotFit) }
            isFallbackPreview = false
            hideWindow()
            return
        }

        if window.contentView !== ghostContent {
            window.contentView = ghostContent
        }
        ghostContent.lines = layout.lines.map { ($0.text, $0.xOffset) }
        ghostContent.metrics = metrics
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
        ghostContent.setAccessibilityValue(candidate)
        ghostContent.setAccessibilityHelp("The completion Cotype would insert with the accept key.")
        ghostContent.needsDisplay = true

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
            .foregroundColor: House.NSColorToken.textPrimary
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
