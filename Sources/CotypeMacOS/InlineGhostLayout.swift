import Foundation
import AppKit

// MARK: - Pure inline ghost text geometry

/// Resolved font/baseline metrics for the inline ghost text.
///
/// Derived from the focused editor's AX attributed string where the host exposes
/// one, so the ghost text uses the same font (and therefore the same line height
/// and baseline) as the text already on screen. When an editor exposes no font
/// (many web/Electron text fields), `.default` supplies a stable proportional
/// metric set so the renderer still has a predictable, non-thrashing layout.
///
/// The numbers are AppKit's own, not invented: the line box is
/// `NSLayoutManager.defaultLineHeight(for:)` and the baseline sits one descent
/// above the bottom of that box, which is where the typesetter puts it (measured
/// for Helvetica 12: box 14, baseline 11; 18: box 22, baseline 18).
public struct GhostTextMetrics: Equatable {
    /// The font the ghost text is drawn with.
    public var font: NSFont
    /// Distance from the top of a line box to its baseline.
    public var ascent: CGFloat
    /// Baseline-to-bottom distance (positive).
    public var descent: CGFloat
    /// Extra leading between lines (zero for AppKit's default line box).
    public var leading: CGFloat
    /// Height of a single line box, and the pitch between ghost lines.
    public var lineHeight: CGFloat
    /// Distance from the top of the line box to the glyph baseline.
    ///
    /// Distinct from `ascent` only by sub-point rounding: the typesetter rounds
    /// the baseline to a whole point, so this is the value the drawing uses.
    public var baselineOffset: CGFloat

    /// Where `NSString.draw(at:)` puts the baseline for this font, measured from
    /// the draw point. Stored because it never changes for a given font.
    private let textBaseline: CGFloat

    public init(font: NSFont) {
        let lineBox = max(NSLayoutManager().defaultLineHeight(for: font), 1)
        self.font = font
        self.lineHeight = lineBox
        self.descent = abs(font.descender)
        self.ascent = max(lineBox - abs(font.descender), 0)
        self.leading = max(lineBox - self.ascent - self.descent, 0)
        self.textBaseline = lineBox - abs(font.descender)
        self.baselineOffset = Self.baselineOffset(forLineBox: lineBox, font: font)
    }

    /// Align the ghost's line box to the editor's own measured line box, so the
    /// ghost's baseline matches the text under the caret and its wrapped lines use
    /// the document's line pitch instead of the fallback font's.
    ///
    /// `measured` is the caret rect's height, which every editor reports as its
    /// line box (a zero-width caret spans exactly one line). It is only trusted
    /// inside a plausible band around the resolved font's own line box: a caret
    /// rect that is much shorter or taller is a selection spanning lines, a whole
    /// field, or a broken value, and then the font metrics are kept as-is.
    public func aligningLineBox(toMeasuredHeight measured: CGFloat) -> GhostTextMetrics {
        guard measured.isFinite, measured > 0,
              measured >= lineHeight * Self.minimumMeasuredLineBoxRatio,
              measured <= lineHeight * Self.maximumMeasuredLineBoxRatio
        else { return self }
        var aligned = self
        aligned.lineHeight = measured
        aligned.baselineOffset = Self.baselineOffset(forLineBox: measured, font: font)
        // Ascent/descent stay the font's own: they are only reported, never drawn.
        return aligned
    }

    /// A measured line box below this fraction of the font's own box is a
    /// mis-read; above the maximum it is a multi-line selection or a field.
    static let minimumMeasuredLineBoxRatio: CGFloat = 0.6
    static let maximumMeasuredLineBoxRatio: CGFloat = 1.8

    /// The baseline the typesetter would use in a line box of `height` for this
    /// font: one descent above the box bottom, rounded to a whole point. A box
    /// taller than the font's own (paragraph/line spacing) keeps the baseline where
    /// the font puts it, because AppKit adds that space below the line.
    static func baselineOffset(forLineBox height: CGFloat, font: NSFont) -> CGFloat {
        let defaultBox = max(NSLayoutManager().defaultLineHeight(for: font), 1)
        let descent = abs(font.descender)
        // Extra height above the font's own box is spacing below the line, so the
        // baseline does not move down with it; a shorter box pulls it up.
        let box = height >= defaultBox ? defaultBox : height
        return max((box - descent).rounded(), 0)
    }

    /// Vertical offset to add to a line-box top before drawing, so the rendered
    /// baseline lands at `baselineOffset` even when the line box was re-measured
    /// from the editor.
    public var baselineDrawOffset: CGFloat {
        baselineOffset - textBaseline
    }

    /// Stable fallback used when the focused editor exposes no font. A fixed font
    /// and size keep the layout non-thrashing across streams (a freshly measured
    /// font per token would otherwise jitter the ghost width on every partial
    /// token). It is proportional on purpose: an unknown editor font is far more
    /// likely to be a UI text face than a code face, and a monospaced ghost is
    /// visibly too wide in prose (measured at 1.7x the document text in TextEdit).
    /// Terminals pass their own monospaced metrics explicitly.
    public static var `default`: GhostTextMetrics {
        GhostTextMetrics(font: NSFont.systemFont(ofSize: 13))
    }
}

/// Pure inline ghost-text layout.
///
/// Given the caret rect, the focused field bounds, the resolved font metrics, and
/// the candidate string, it computes where the ghost text should sit so it reads
/// as a continuation of the editor's own text at the insertion point:
///
/// - the first line begins at the caret's x position,
/// - overflowing words wrap to subsequent lines that align to the editor's text
///   column (the natural continuation of a wrapped editor line),
/// - the block is clipped to `maxLines`, signalling the clip with `wasClipped`,
/// - the block never exceeds the field width or height.
///
/// Everything is computed in the AX global coordinate space (origin at the
/// top-left of the primary display, y increasing downward) so it lines up with
/// the rects `AXCaretGeometryProvider` reads. All text measuring is injected via
/// `measure`, which keeps this pure and unit-testable without AppKit font drawing.
public enum InlineGhostLayout {

    /// One rendered line of ghost text.
    public struct Line: Equatable, Sendable {
        public var text: String
        /// Leading x offset of this line relative to the block's left edge.
        public var xOffset: CGFloat

        public init(text: String, xOffset: CGFloat) {
            self.text = text
            self.xOffset = xOffset
        }
    }

    public struct Result: Equatable, Sendable {
        /// Top-left origin of the ghost block in AX global coordinates (y-down).
        public var origin: NSPoint
        /// Size of the ghost block.
        public var size: NSSize
        /// The wrapped lines, clipped to `maxLines`.
        public var lines: [Line]
        /// True when the candidate produced more lines than `maxLines`.
        public var wasClipped: Bool

        public init(origin: NSPoint, size: NSSize, lines: [Line], wasClipped: Bool) {
            self.origin = origin
            self.size = size
            self.lines = lines
            self.wasClipped = wasClipped
        }
    }

    /// Compute the ghost text block for a candidate at `caretRect`, wrapped and
    /// clipped within `fieldBounds`.
    ///
    /// - Parameters:
    ///   - caretRect: the caret's character-range bounds in AX global coords.
    ///   - fieldBounds: the focused field's bounds in AX global coords.
    ///   - metrics: resolved font/baseline metrics (drives line height).
    ///   - maxLines: maximum number of lines to render before clipping.
    ///   - textInset: distance from the field's leading edge to the editor's text
    ///     column, as measured from AX line geometry. Wrapped and hard-broken lines
    ///     start here; 0 keeps the field edge (the conservative default when the
    ///     column cannot be measured).
    ///   - candidate: the completion text to lay out.
    ///   - measure: returns the width (in points) of a given substring in the
    ///     resolved glyph metrics. Injected so this is deterministic in tests.
    public static func layout(
        caretRect: CGRect,
        fieldBounds: CGRect,
        metrics: GhostTextMetrics,
        maxLines: Int = 3,
        textInset: CGFloat = 0,
        candidate: String,
        measure: (String) -> CGFloat
    ) -> Result {
        let lineHeight = max(metrics.lineHeight, 1)
        let fieldMinX = fieldBounds.minX
        let fieldMaxX = fieldBounds.maxX
        let fieldWidth = max(fieldBounds.width, 0)
        let inset = clampedTextInset(textInset, fieldBounds: fieldBounds)
        let textMinX = fieldMinX + inset
        let limit = max(maxLines, 1)

        let chunks = chunks(of: candidate)
        var lines: [Line] = []
        var current = ""
        var currentLeftX = caretRect.minX
        var firstLine = true

        // Greedy soft-wrap that preserves the candidate's exact whitespace and
        // line breaks. Spaces stay verbatim (so indentation renders); a newline is
        // a hard break that always starts a fresh line regardless of width.
        for chunk in chunks {
            switch chunk.kind {
            case .newline:
                // Explicit line break: flush the running line, then continue at the
                // text column's leading edge (drop trailing spaces before this break).
                lines.append(Line(
                    text: trimTrailingWhitespace(current),
                    xOffset: currentLeftX - fieldMinX
                ))
                current = ""
                firstLine = false
                currentLeftX = textMinX

            case .space:
                // Preserve whitespace verbatim (indentation and word separators).
                // Trailing whitespace is trimmed when the line is flushed at a break.
                current += chunk.text

            case .word:
                let proposed = current + chunk.text
                if current.isEmpty {
                    // Always place the first word of a line even if it overflows; it
                    // clips rather than drifting to another line.
                    current = proposed
                } else if measure(proposed) <= availableWidth(
                    firstLine: firstLine,
                    currentLeftX: currentLeftX,
                    fieldMaxX: fieldMaxX,
                    textMinX: textMinX
                ) {
                    current = proposed
                } else {
                    // Soft wrap at a word boundary: flush the line, dropping the
                    // trailing whitespace, and start the next line at the text column.
                    lines.append(Line(
                        text: trimTrailingWhitespace(current),
                        xOffset: currentLeftX - fieldMinX
                    ))
                    current = chunk.text
                    firstLine = false
                    currentLeftX = textMinX
                }
            }
        }
        if !current.isEmpty {
            lines.append(Line(text: current, xOffset: currentLeftX - fieldMinX))
        }

        var wasClipped = false
        var outLines = lines
        if outLines.count > limit {
            outLines = Array(outLines.prefix(limit))
            wasClipped = true
            if let last = outLines.last {
                outLines[outLines.count - 1] = Line(text: last.text + "…", xOffset: last.xOffset)
            }
        }

        // Block origin: the block starts at the field's leading edge (the caret is
        // always inside the field) and at the caret line's top.
        let origin = NSPoint(x: fieldMinX, y: caretRect.minY)

        // Block width: the furthest right extent of any line, clamped to the field
        // width so the transparent window never spills past the field. Height is
        // one line box per rendered line, clamped to the field's remaining vertical
        // space below the caret line so the ghost never escapes the field.
        var maxExtent: CGFloat = 0
        for line in outLines {
            maxExtent = max(maxExtent, line.xOffset + measure(line.text))
        }
        let blockWidth = min(max(maxExtent, 0), fieldWidth)

        var blockHeight = CGFloat(outLines.count) * lineHeight
        let availableVertical = max(fieldBounds.maxY - origin.y, lineHeight)
        if blockHeight > availableVertical {
            blockHeight = availableVertical
            wasClipped = true
        }

        return Result(
            origin: origin,
            size: NSSize(width: blockWidth, height: blockHeight),
            lines: outLines,
            wasClipped: wasClipped
        )
    }

    /// Human-readable one-line description, used by diagnostics.
    public static func describe(_ result: Result) -> String {
        result.lines.map { $0.text }.joined(separator: " / ")
    }

    private static func availableWidth(
        firstLine: Bool,
        currentLeftX: CGFloat,
        fieldMaxX: CGFloat,
        textMinX: CGFloat
    ) -> CGFloat {
        // On the caret line the text may only run to the field's trailing edge;
        // wrapped lines get the width of the text column, which starts at the
        // measured inset and still ends at the field's trailing edge. No right
        // inset is invented: the column's own right edge is not measured, and
        // stopping at the field keeps the window inside it.
        firstLine ? max(fieldMaxX - currentLeftX, 0) : max(fieldMaxX - textMinX, 0)
    }

    /// Keep a measured text-column inset usable: finite, positive, narrower than
    /// the field, and leaving at least half the field for the ghost's own text.
    /// Anything else is a mis-read column, so the ghost stays on the field edge.
    static func clampedTextInset(_ inset: CGFloat, fieldBounds: CGRect) -> CGFloat {
        let width = fieldBounds.width
        guard inset.isFinite, inset > 0, width > 0, width.isFinite, inset < width else { return 0 }
        return min(inset, width / 2)
    }

    /// A run of same-category characters. Splitting into these preserves the
    /// candidate's exact characters so wrapping never re-spaces or drops newlines.
    private struct Chunk {
        enum Kind: Equatable { case word, space, newline }
        let kind: Kind
        let text: String
    }

    private static func chunks(of string: String) -> [Chunk] {
        var result: [Chunk] = []
        var buffer = ""
        var bufferKind: Chunk.Kind?

        func kind(of c: Character) -> Chunk.Kind {
            if c.isNewline { return .newline }
            if c.isWhitespace { return .space }
            return .word
        }

        for c in string {
            let k = kind(of: c)
            if let bk = bufferKind, bk == k {
                buffer.append(c)
            } else {
                if let bk = bufferKind, !buffer.isEmpty {
                    result.append(Chunk(kind: bk, text: buffer))
                }
                buffer = String(c)
                bufferKind = k
            }
        }
        if let bk = bufferKind, !buffer.isEmpty {
            result.append(Chunk(kind: bk, text: buffer))
        }
        return result
    }

    /// Drop trailing spaces/tabs (but keep newlines, which are separate chunks)
    /// so a break does not leave dangling whitespace at a line end.
    private static func trimTrailingWhitespace(_ s: String) -> String {
        var s = s
        while let last = s.last, last.isWhitespace, !last.isNewline {
            s.removeLast()
        }
        return s
    }
}
