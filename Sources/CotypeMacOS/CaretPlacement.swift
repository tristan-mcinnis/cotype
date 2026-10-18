import Foundation
import AppKit
import ApplicationServices
import CotypeCore

// MARK: - AX to AppKit origin flip

/// Converts inline ghost-text geometry from the Accessibility coordinate space
/// into an AppKit window-frame origin.
///
/// The overlay is inline only: it is drawn at the caret, so there is no mouse
/// anchor, no preferred offset, and no screen clamping. This single flip is the
/// only placement geometry the renderer needs.
public enum CaretPlacement {

    /// Convert an AX global top-left origin (y increasing downward, origin at the
    /// primary display's top-left) to an AppKit window-frame origin (bottom-left
    /// corner, y increasing upward) for a window of the given `size`.
    ///
    /// The two coordinate systems are mirrors of each other across the primary
    /// display, so the flip needs only the primary display's height in points.
    public static func toAppKitWindowOrigin(axTopLeft: NSPoint, size: NSSize, primaryScreenHeight: CGFloat) -> NSPoint {
        NSPoint(x: axTopLeft.x, y: primaryScreenHeight - axTopLeft.y - size.height)
    }
}

// MARK: - Inline caret geometry

/// Geometry inputs for inline ghost-text placement, read from the focused
/// editor's Accessibility tree.
///
/// All rects are in the AX global coordinate space: origin at the primary
/// display's top-left corner, x increasing right, y increasing **downward**.
public struct CaretGeometry {
    /// Bounds of the caret character range (a zero-width insertion caret when the
    /// selection is empty). Height is the line box height.
    public var caretRect: CGRect
    /// Bounds of the focused text field / editor.
    public var fieldBounds: CGRect
    /// Resolved font metrics, or `.default` when the editor exposes no font.
    public var metrics: GhostTextMetrics
    /// Distance from the field's leading edge to the editor's text column,
    /// measured from the caret line's own AX character bounds. 0 means "not
    /// measured": the ghost then wraps at the field edge exactly as before.
    public var textInset: CGFloat

    public init(
        caretRect: CGRect,
        fieldBounds: CGRect,
        metrics: GhostTextMetrics = .default,
        textInset: CGFloat = 0
    ) {
        self.caretRect = caretRect
        self.fieldBounds = fieldBounds
        self.metrics = metrics
        self.textInset = textInset
    }
}

/// Resolves the focused editor's caret rect, field bounds, and font metrics so
/// the renderer can place inline ghost text at the insertion point.
///
/// Returning nil means the caret could not be resolved safely. Callers must NOT
/// fall back to the mouse — an unknown caret is treated as "do not show", never
/// as a guessed position.
public protocol InlineCaretGeometryProvider {
    func caretGeometry() -> CaretGeometry?
}

/// Bounds of the focused field without a caret. Used only by the explicit
/// fallback preview, which anchors to the field's own bottom-left corner instead
/// of guessing a caret position.
public struct CaretFieldGeometry {
    public var fieldBounds: CGRect
    public var metrics: GhostTextMetrics

    public init(fieldBounds: CGRect, metrics: GhostTextMetrics) {
        self.fieldBounds = fieldBounds
        self.metrics = metrics
    }
}

/// An optional capability of a geometry provider: the focused field's bounds
/// even when no caret rect can be resolved.
public protocol InlineFieldGeometryProvider {
    func fieldGeometry() -> CaretFieldGeometry?
}

/// The ordered caret-rect strategies the AX provider tries. The first strategy
/// that produces bounds inside the focused field wins; when none does, the
/// provider returns nil and the renderer hides. Nothing here guesses: every
/// strategy reads real text geometry, and the ladder is only about which real
/// geometry to ask for after an editor declines to answer.
enum CaretRectStrategy: String, CaseIterable, Sendable {
    /// `kAXSelectedTextRange` bounds via `kAXBoundsForRange`. The caret case is a
    /// zero-length range; a non-empty selection anchors at its leading edge,
    /// which is where an accepted completion would replace the selection.
    case selectedRangeBounds
    /// Bounds of the character before the caret, converted to a 1 pt caret at
    /// that character's trailing edge. Covers editors whose zero-length range
    /// yields no usable rect but whose character ranges do.
    case precedingCharacterBounds
    /// `kAXSelectedTextMarkerRange` fed to `kAXBoundsForTextMarkerRange`.
    /// WebKit/Chromium editors expose text markers where they expose no
    /// `kAXBoundsForRange` at all.
    case textMarkerRangeBounds
}

/// Resolves the focused editor's caret geometry through the Accessibility API
/// using a bounded strategy ladder.
///
/// Editors disagree about how to report a caret. This provider asks in the order
/// that works most widely — the selected range, then the character before the
/// caret, then the web/custom-editor text-marker API — and takes the first rect
/// that is real enough to draw at. Every rect is validated against the focused
/// field's bounds, so an implausible answer falls through to the next strategy
/// instead of placing an overlay, and running out of strategies returns nil so
/// the renderer hides rather than mis-placing an overlay.
///
/// Geometry is only ever read from the focused editor's own AX text. This never
/// consults the mouse pointer, never guesses a frame from the window or a sibling
/// element, and never falls back to a detached pane.
public struct AXCaretGeometryProvider: InlineCaretGeometryProvider, InlineFieldGeometryProvider {
    public init() {}

    /// How far up the AX tree the text-marker step looks for the element that
    /// owns the marker range. WebKit exposes `kAXSelectedTextMarkerRange` on the
    /// web area rather than on the focused contenteditable node, so a shallow
    /// walk is the difference between "no caret" and a real caret there. The
    /// walk is bounded because it only ever runs after both range strategies
    /// have already failed.
    static let textMarkerAncestorLimit = 3

    public func caretGeometry() -> CaretGeometry? {
        // AX reads are thread-sensitive; callers are already on the main actor.
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let focused = AXFocusedEditorResolver.resolve(in: app)
        else { return nil }
        return geometry(of: focused, bundleIdentifier: app.bundleIdentifier ?? "")
    }

    /// Geometry for one already-resolved editor element. Internal so a live probe
    /// can ask an app that is not frontmost (the probe must not steal focus).
    func geometry(of focused: AXUIElement, bundleIdentifier: String) -> CaretGeometry? {
        guard let fieldBounds = frameAttribute(of: focused) else { return nil }

        if AppCompatibility.isTerminal(bundleIdentifier) {
            return MainActor.assumeIsolated { TerminalCaret.geometry(element: focused, field: fieldBounds) }
        }

        // Read once and reuse: the ladder's first two steps both need it, and the
        // font and column probes below need it again.
        let range = selectedRange(of: focused)

        guard let caretRect = resolveCaretRect(
            in: focused,
            selectedRange: range,
            fieldBounds: fieldBounds
        ) else { return nil }

        // Read the document length once: both probes below are bounded by it, and
        // `kAXValue` copies the whole text, so asking twice is wasted work.
        let documentLength = valueLength(of: focused)

        // Baseline/font metrics resolved from the field's own attributed text when
        // the host exposes it, so the ghost uses the same font and baselines. The
        // resolved line box is then fitted to the caret's own measured line box:
        // that is what makes the ghost's baseline match the text under it, whether
        // or not the host named the right font.
        let font = range.flatMap {
            attributedFontMetrics(of: focused, range: $0, documentLength: documentLength)
        }
        let base = font.map(GhostTextMetrics.init(font:)) ?? GhostTextMetrics.default
        let metrics = base.aligningLineBox(toMeasuredHeight: caretRect.height)

        // The text column's leading edge, measured from the caret line's character
        // bounds. 0 when the host does not answer or the line is not a plain
        // left-to-right column.
        let textInset = range.flatMap {
            textColumnInset(
                of: focused,
                caretRange: $0,
                documentLength: documentLength,
                caretRect: caretRect,
                fieldBounds: fieldBounds
            )
        } ?? 0

        CotypeLog.geometry.debug("""
        ghost font=\(metrics.font.fontName, privacy: .public) size=\(metrics.font.pointSize, privacy: .public) \
        line=\(metrics.lineHeight, privacy: .public) baseline=\(metrics.baselineOffset, privacy: .public) \
        inset=\(textInset, privacy: .public)
        """)

        return CaretGeometry(
            caretRect: caretRect,
            fieldBounds: fieldBounds,
            metrics: metrics,
            textInset: textInset
        )
    }

    /// Field bounds and font for the opt-in fallback preview. This never invents
    /// a caret: it returns only the focused element's real frame and the font of
    /// its nearest readable text, or nil.
    public func fieldGeometry() -> CaretFieldGeometry? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let focused = AXFocusedEditorResolver.resolve(in: app),
              let fieldBounds = frameAttribute(of: focused)
        else { return nil }
        let metrics = selectedRange(of: focused)
            .flatMap {
                attributedFontMetrics(
                    of: focused,
                    range: $0,
                    documentLength: valueLength(of: focused)
                )
            }
            .map(GhostTextMetrics.init(font:)) ?? .default
        return CaretFieldGeometry(fieldBounds: fieldBounds, metrics: metrics)
    }

    /// The caret-rect ladder. Steps are closures so they are evaluated lazily:
    /// the common path (a native editor with a readable selected range) costs one
    /// bounds read and never touches the text-marker API.
    private func resolveCaretRect(
        in element: AXUIElement,
        selectedRange: CFRange?,
        fieldBounds: CGRect
    ) -> CGRect? {
        if let rect = caretRect(on: element, selectedRange: selectedRange, fieldBounds: fieldBounds, log: true) {
            return rect
        }
        if let marker = textMarkerCaretRect(near: element, inside: fieldBounds) {
            CotypeLog.geometry.debug("caret via textMarkerRangeBounds")
            return marker
        }
        // KeyType and cotabby: Chromium/Electron often keep the live caret on a
        // deep descendant (an AXStaticText leaf or an inner text node), not on
        // the focused editor. Search a bounded subtree for a node with a
        // collapsed selection and usable bounds.
        if let deep = deepDescendantCaret(under: element, fieldBounds: fieldBounds) {
            CotypeLog.geometry.debug("caret via deepDescendant")
            return deep
        }
        return nil
    }

    /// The TabType ladder on one element: zero-length bounds cross-checked
    /// against the previous character's trailing edge.
    private func caretRect(
        on element: AXUIElement,
        selectedRange: CFRange?,
        fieldBounds: CGRect,
        log: Bool
    ) -> CGRect? {
        guard let caretRange = selectedRange.flatMap({ $0.location >= 0 && $0.length >= 0 ? $0 : nil }) else {
            if log { CotypeLog.geometry.info("no caret: no selection range") }
            return nil
        }
        let rawZero = boundsForRange(of: element, range: caretRange)
        let rawAnchor = precedingCharacterCaretRect(of: element, caretRange: caretRange)
        let zero = rawZero.flatMap { Self.isUsableCaretRect($0, inside: fieldBounds) ? $0 : nil }
        let anchor = rawAnchor.flatMap { Self.isUsableCaretRect($0, inside: fieldBounds) ? $0 : nil }
        let isWeb = attribute(element, kAXSelectedTextMarkerRangeAttribute) != nil
        if let chosen = Self.reconcileCaret(zeroLength: zero, anchor: anchor, isWebContent: isWeb) {
            if log { CotypeLog.geometry.debug("caret via \(chosen.strategy.rawValue, privacy: .public)") }
            return chosen.rect
        }
        if log {
            // Geometry only, never text: enough to tell a scaled, off-field, or
            // missing rect apart.
            CotypeLog.geometry.info("""
            no caret: loc=\(caretRange.location, privacy: .public) web=\(isWeb, privacy: .public) \
            field=\(String(describing: fieldBounds), privacy: .public) \
            zero=\(rawZero.map { String(describing: $0) } ?? "nil", privacy: .public) \
            prev=\(rawAnchor.map { String(describing: $0) } ?? "nil", privacy: .public)
            """)
        }
        return nil
    }

    static let deepSearchMaxNodes = 200
    static let deepSearchMaxDepth = 10

    private func deepDescendantCaret(under root: AXUIElement, fieldBounds: CGRect) -> CGRect? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        // A descendant's own frame can be a single line; validate against the
        // editor's frame with KeyType's 80 pt halo instead.
        let halo = fieldBounds.insetBy(dx: -80, dy: -80)
        while cursor < queue.count, cursor < Self.deepSearchMaxNodes {
            let (node, depth) = queue[cursor]
            cursor += 1
            if depth > 0,
               let range = selectedRange(of: node), range.length == 0,
               let rect = caretRect(on: node, selectedRange: range, fieldBounds: halo, log: false) {
                return rect
            }
            guard depth < Self.deepSearchMaxDepth,
                  let children = attributeValue(node, kAXChildrenAttribute) as [AXUIElement]? else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        CotypeLog.geometry.info("no caret: deep search found nothing in \(cursor, privacy: .public) nodes")
        return nil
    }

    /// Pure choice between the zero-length caret rect and the previous
    /// character's trailing-edge anchor (TabType `caretRect(of:)`).
    static func reconcileCaret(
        zeroLength: CGRect?,
        anchor: CGRect?,
        isWebContent: Bool
    ) -> (strategy: CaretRectStrategy, rect: CGRect)? {
        switch (zeroLength, anchor) {
        case let (zero?, anchor?):
            if isWebContent { return (.precedingCharacterBounds, anchor) }
            let agrees = abs(zero.minX - anchor.minX) <= 24 && abs(zero.minY - anchor.minY) <= 6
            return agrees ? (.selectedRangeBounds, zero) : (.precedingCharacterBounds, anchor)
        case let (zero?, nil):
            return (.selectedRangeBounds, zero)
        case let (nil, anchor?):
            return (.precedingCharacterBounds, anchor)
        case (nil, nil):
            return nil
        }
    }

    /// The ladder itself, as a pure function: walk the strategies in order and
    /// return the first candidate rect that passes the field-bounds gate. Each
    /// candidate is produced by a closure, so a strategy that is never reached is
    /// never evaluated (and therefore never posts an AX round trip).
    static func firstUsableCaret(
        inside field: CGRect,
        _ candidates: [(strategy: CaretRectStrategy, rect: () -> CGRect?)]
    ) -> (strategy: CaretRectStrategy, rect: CGRect)? {
        for candidate in candidates {
            guard let rect = candidate.rect(), isUsableCaretRect(rect, inside: field) else { continue }
            return (candidate.strategy, rect)
        }
        return nil
    }

    /// Which edge of a character cell a caret sits on.
    enum CaretEdge: Sendable {
        case leading
        case trailing
    }

    /// Convert the bounds of a single character into a 1 pt insertion caret.
    ///
    /// A caret sits on an edge of a character cell, not on the character itself,
    /// so this keeps the character's line-box origin and height and only chooses
    /// the x. `trailing` is the normal case (the caret follows the character
    /// before it, so it lands on `maxX`); `leading` covers document start, where
    /// there is no preceding character and the caret sits before the first one.
    /// Character bounds with no line height return nil so the caller falls
    /// through rather than inventing a line.
    static func caretRect(fromCharacterBounds bounds: CGRect, at edge: CaretEdge) -> CGRect? {
        guard bounds.height > 0 else { return nil }
        let x = edge == .trailing ? bounds.maxX : bounds.minX
        return CGRect(x: x, y: bounds.minY, width: 1, height: bounds.height)
    }

    /// Turn the character before the caret into a caret rect. At document start
    /// there is no preceding character, so the first character's leading edge is
    /// the only honest answer; otherwise the caret is the trailing edge of the
    /// character immediately before it.
    private func precedingCharacterCaretRect(of element: AXUIElement, caretRange: CFRange) -> CGRect? {
        let probe = Self.fontProbeRange(for: caretRange, documentLength: valueLength(of: element))
        guard probe.length > 0,
              let characterBounds = boundsForRange(of: element, range: probe)
        else { return nil }

        return Self.caretRect(
            fromCharacterBounds: characterBounds,
            at: Self.caretEdge(forCaretRange: caretRange)
        )
    }

    /// Which edge of the probed character cell the caret sits on. The probe
    /// prefers the character before the caret, so the caret is on that
    /// character's trailing edge; at document start the probe is the character
    /// after the caret, and the caret is on its leading edge.
    static func caretEdge(forCaretRange caretRange: CFRange) -> CaretEdge {
        caretRange.location > 0 ? .trailing : .leading
    }

    /// The caret bounds from the web/custom-editor text-marker API:
    /// `kAXSelectedTextMarkerRange` (an opaque `AXTextMarkerRange`) fed back to
    /// the `kAXBoundsForTextMarkerRange` parameterized attribute. Chromium and
    /// WebKit contenteditable editors routinely answer neither `kAXBoundsForRange`
    /// call above but do answer this one.
    private func textMarkerCaretRect(near element: AXUIElement, inside fieldBounds: CGRect) -> CGRect? {
        var current: AXUIElement? = element
        var ancestorsRemaining = Self.textMarkerAncestorLimit
        while let candidate = current {
            if let rect = boundsForTextMarkerRange(of: candidate),
               Self.isUsableCaretRect(rect, inside: fieldBounds) {
                return rect
            }
            guard ancestorsRemaining > 0 else { return nil }
            ancestorsRemaining -= 1
            current = attributeValue(candidate, kAXParentAttribute) as AXUIElement?
        }
        return nil
    }

    /// `kAXBoundsForTextMarkerRange` for one element, or nil when the element
    /// exposes no marker range. The value is type-checked before it is passed
    /// back: the attribute name is shared by other AX object types, and handing
    /// garbage to the parameterized call would only fail silently.
    private func boundsForTextMarkerRange(of element: AXUIElement) -> CGRect? {
        guard let markerRange = attribute(element, kAXSelectedTextMarkerRangeAttribute),
              CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        return parameterizedRect(
            element,
            attribute: kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            parameter: markerRange
        )
    }

    // MARK: - AX attribute helpers

    /// Read a single AX attribute, returning nil on any error or missing value.
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return error == .success ? value : nil
    }

    private func attributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        guard let value = attribute(element, key) else { return nil }
        return value as? T
    }

    /// The selected-text range (kAXSelectedTextRange) as a CFRange, if present.
    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let axValue = attributeValue(element, kAXSelectedTextRangeAttribute) as AXValue?,
              AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The CGRect bounds of a character range via `kAXBoundsForRange`.
    private func boundsForRange(of element: AXUIElement, range: CFRange) -> CGRect? {
        var r = range
        guard let parameter = AXValueCreate(.cfRange, &r) else { return nil }
        return parameterizedRect(
            element,
            attribute: kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter: parameter
        )
    }

    /// The focused field's frame as a CGRect in AX global coords. Built from the
    /// element's position (AXPosition, a point) and size (AXSize) attributes;
    /// `kAXFrame` is not exported on the modern SDK.
    private func frameAttribute(of element: AXUIElement) -> CGRect? {
        guard let origin = positionAttribute(of: element),
              let size = sizeAttribute(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// AXPosition of an element as a CGPoint (top-left origin, y-down).
    private func positionAttribute(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// AXSize of an element as a CGSize.
    private func sizeAttribute(of element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Resolve the editor's font from the attributed string just before the caret
    /// (kAXAttributedStringForRange). A zero-length caret range yields an empty
    /// attributed string, so we probe one character — the one immediately before
    /// the caret (or the first after it at document start) — to read the font the
    /// user is actually typing with. The caret-bounds lookup above still uses the
    /// real caret range. Returns nil when the host exposes no attributed text
    /// (common in web/Electron) or no decodable font on it.
    ///
    /// The font may arrive as a Cocoa `NSFont` or as the standard Accessibility
    /// `AXFont` dictionary; `AXFontDecoder` handles both. Only font attributes are
    /// read here — never the characters.
    private func attributedFontMetrics(
        of element: AXUIElement,
        range: CFRange,
        documentLength: Int
    ) -> NSFont? {
        // Prefer probing the character before the caret so the ghost font matches
        // the text under the insertion point.
        let probe = Self.fontProbeRange(for: range, documentLength: documentLength)
        guard probe.length > 0 else { return nil }
        var r = probe
        guard let parameter = AXValueCreate(.cfRange, &r) else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        guard err == .success,
              let value,
              CFGetTypeID(value) == CFAttributedStringGetTypeID(),
              let attributed = value as? NSAttributedString
        else { return nil }

        return AXFontDecoder.font(from: attributed)
    }

    // MARK: - Text column inset

    /// Distance from the field's leading edge to the leading edge of the caret
    /// line's text column, read from that line's own AX character bounds.
    ///
    /// A text view's frame includes its container padding, so wrapping at the
    /// field's edge draws the continuation left of where the document's own lines
    /// start. This asks the editor for the truth instead of assuming a margin: the
    /// caret's line number (`kAXLineForIndex`), that line's range
    /// (`kAXRangeForLine`), and the bounds of its first and last characters. Every
    /// step is optional; any unsupported attribute or implausible rect returns nil
    /// and the ghost keeps the field edge.
    private func textColumnInset(
        of element: AXUIElement,
        caretRange: CFRange,
        documentLength: Int,
        caretRect: CGRect,
        fieldBounds: CGRect
    ) -> CGFloat? {
        guard documentLength > 0 else { return nil }
        // The probe character sits on the caret's own line (before the caret, or
        // the first character at document start).
        let probe = Self.fontProbeRange(for: caretRange, documentLength: documentLength)
        guard probe.length > 0,
              let line = lineNumber(of: element, forCharacterAt: probe.location),
              let lineRange = rangeForLine(of: element, line: line),
              lineRange.length > 0,
              lineRange.location >= 0,
              lineRange.location < documentLength,
              let firstCharacter = boundsForRange(
                  of: element,
                  range: CFRange(location: lineRange.location, length: 1)
              )
        else { return nil }

        let lastIndex = min(lineRange.location + lineRange.length - 1, documentLength - 1)
        let lastCharacter = lastIndex > lineRange.location
            ? boundsForRange(of: element, range: CFRange(location: lastIndex, length: 1))
            : nil

        return Self.textColumnInset(
            firstCharacter: firstCharacter,
            lastCharacter: lastCharacter,
            caretRect: caretRect,
            fieldBounds: fieldBounds
        )
    }

    /// Pure inset decision. Accepts only a plain left-to-right text column inside
    /// the field:
    ///
    /// - the line's first character must share the caret's line box, so a stale or
    ///   scrolled line range cannot move the ghost;
    /// - the first character must be left of the line's last character when the
    ///   last character has usable bounds. On a right-to-left line the logical
    ///   first character is the rightmost one, and applying a left inset there
    ///   would push the continuation into the middle of the text;
    /// - the caret must not sit left of the column it is in, and the inset must be
    ///   small enough to leave room for the ghost's own text.
    ///
    /// Everything else returns nil, which means inset 0: the ghost stays where it
    /// is drawn today rather than at a guessed margin.
    static func textColumnInset(
        firstCharacter: CGRect,
        lastCharacter: CGRect?,
        caretRect: CGRect,
        fieldBounds: CGRect
    ) -> CGFloat? {
        guard fieldBounds.width > 0, fieldBounds.height > 0,
              caretRect.height > 0,
              firstCharacter.height > 0, firstCharacter.height.isFinite,
              firstCharacter.width >= 0, firstCharacter.width.isFinite,
              firstCharacter.minX.isFinite, firstCharacter.minY.isFinite
        else { return nil }

        // Same line box as the caret (a caret can be reported a point or two off
        // the character's own top, so the tolerance is half a line).
        let lineTolerance = max(1, caretRect.height * 0.5)
        guard abs(firstCharacter.minY - caretRect.minY) <= lineTolerance else { return nil }

        let inset = firstCharacter.minX - fieldBounds.minX
        guard inset.isFinite, inset > 0 else { return nil }

        // Confirmed direction when the line's last character has real bounds.
        var leftToRight: Bool?
        if let lastCharacter,
           lastCharacter.height > 0,
           lastCharacter.width > 0,
           abs(lastCharacter.minY - firstCharacter.minY) <= lineTolerance {
            leftToRight = lastCharacter.minX >= firstCharacter.minX
        }
        if leftToRight == false { return nil }

        // A confirmed line may carry a wide margin; an unconfirmed one (a line
        // ending in a newline, whose bounds are often empty) only a narrow one.
        let limit = leftToRight == true ? 0.35 : 0.25
        guard inset < fieldBounds.width * limit else { return nil }

        // The caret sits at or right of its column's leading edge. On a
        // right-to-left line every other character is left of the first, so this
        // also rejects the remaining unconfirmed RTL cases.
        guard caretRect.minX >= firstCharacter.minX - 0.5 else { return nil }
        return inset
    }

    /// The line number containing a character index (`kAXLineForIndex`).
    private func lineNumber(of element: AXUIElement, forCharacterAt index: Int) -> Int? {
        guard index >= 0 else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: index),
            &value
        )
        guard err == .success, let value else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// A line's character range (`kAXRangeForLine`).
    private func rangeForLine(of element: AXUIElement, line: Int) -> CFRange? {
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            NSNumber(value: line),
            &value
        )
        guard err == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The focused element's text length, used to bound the font-probe range.
    private func valueLength(of element: AXUIElement) -> Int {
        guard let value = attributeValue(element, kAXValueAttribute) as String? else { return 0 }
        return (value as NSString).length
    }

    /// Read an AX parameterized attribute that returns a CGRect (AXValue of type
    /// .cgRect). This is the correct decoder for `kAXBoundsForRange`; the buggy
    /// point-based decoder is gone.
    private func parameterizedRect(_ element: AXUIElement, attribute: CFString, parameter: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard err == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        return Self.decodeCGRect(from: axValue)
    }

    /// Decode an AXValue as a CGRect, rejecting any other AXValue type. This is the
    /// correct decoder for `kAXBoundsForRange` (which returns a .cgRect). The old
    /// point decoder read only the first 8 bytes of the CGRect, producing a broken
    /// caret position; a type check is the only thing that prevents that.
    static func decodeCGRect(from axValue: AXValue) -> CGRect? {
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The single gate every ladder strategy passes through: reject bogus
    /// Electron/Chromium caret bounds (commonly a zero-height rect at the window
    /// edge, or a rect belonging to a sibling element) so the renderer fails
    /// closed instead of drawing an invisible inline window off the field.
    ///
    /// Geometry genuinely past the field's edges is still rejected: only a caret
    /// whose own insertion point is inside the field is accepted.
    static func isUsableCaretRect(_ caret: CGRect, inside field: CGRect) -> Bool {
        // Heights outside 1...200 pt are line boxes or whole fields, not a caret.
        guard caret.width >= 0,
              caret.height > 1,
              caret.height < 200,
              caret.origin.x.isFinite, caret.origin.y.isFinite,
              field.width > 0,
              field.height > 0
        else { return false }
        return field.intersects(caret) || isInsertionPointInside(caret, field)
    }

    /// Whether the caret's insertion point — its leading edge, over its full line
    /// box — lies inside `field`, trailing and bottom edges included.
    ///
    /// `intersects` is not enough on its own: it is false for both end-of-line
    /// carets that matter here — a zero-width caret exactly on the field's
    /// trailing edge, and the 1 pt caret the character-bounds step builds there,
    /// whose own thickness crosses that edge. Both are real insertion points, and
    /// rejecting them would make the ghost vanish at the end of a full line. This
    /// test replaces `CGRect.contains`, which is half-open on `maxX`/`maxY` for
    /// the same reason, and it fully covers inclusive containment: a rect whose
    /// trailing edge is inside the field also has its leading edge inside it.
    private static func isInsertionPointInside(_ caret: CGRect, _ field: CGRect) -> Bool {
        caret.minX >= field.minX && caret.minX <= field.maxX
            && caret.minY >= field.minY && caret.maxY <= field.maxY
    }

    /// Pure range selector for the font probe. Prefers the character immediately
    /// before the caret so the ghost font matches the text being typed; at document
    /// start (nothing before the caret) it probes the first character after it.
    static func fontProbeRange(for caretRange: CFRange, documentLength: Int) -> CFRange {
        let len = max(documentLength, 0)
        if caretRange.location > 0, caretRange.location - 1 < len {
            return CFRange(location: caretRange.location - 1, length: 1)
        }
        if len > 0 {
            return CFRange(location: 0, length: 1)
        }
        return CFRange(location: 0, length: 0)
    }
}
