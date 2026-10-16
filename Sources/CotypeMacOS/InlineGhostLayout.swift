import Foundation
import AppKit

// MARK: - Pure inline ghost text geometry

/// Resolved font/baseline metrics for the inline ghost text.
///
/// Derived from the focused editor's AX attributed string where the host exposes
/// one, so the ghost text uses the same font (and therefore the same line height
/// and baseline) as the text already on screen. When an editor exposes no font
/// (many web/Electron text fields), `.default` supplies a stable monospaced
/// metric set so the renderer still has a predictable, non-thrashing layout.
public struct GhostTextMetrics: Equatable {
    /// The font the ghost text is drawn with.
    public var font: NSFont
    /// Distance from the top of a line box to its baseline.
    public var ascent: CGFloat
    /// Baseline-to-bottom distance (positive).
    public var descent: CGFloat
    /// Extra leading between lines.
    public var leading: CGFloat
    /// Height of a single text line.
    public var lineHeight: CGFloat

    public init(font: NSFont) {
        self.font = font
        self.ascent = font.ascender
        self.descent = abs(font.descender)
        self.leading = font.leading
        // Round each component up so a line box is never taller than the sum of
        // its parts but always fits the glyphs, matching how AppKit lays text out.
        self.lineHeight = max(
            ceil(font.ascender) + ceil(abs(font.descender)) + font.leading,
            font.pointSize
        )
    }

    /// Stable fallback used when the focused editor exposes no font. A fixed size
    /// keeps the layout non-thrashing across streams (a freshly measured font per
    /// token would otherwise jitter the ghost width on every partial token).
    public static var `default`: GhostTextMetrics {
        GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }
}

/// Pure inline ghost-text layout.
///
/// Given the caret rect, the focused field bounds, the resolved font metrics, and
/// the candidate string, it computes where the ghost text should sit so it reads
/// as a continuation of the editor's own text at the insertion point:
///
/// - the first line begins at the caret's x position,
/// - overflowing words wrap to subsequent lines that align to the field's leading
///   edge (the natural continuation of a wrapped editor line),
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
    ///   - candidate: the completion text to lay out.
    ///   - measure: returns the width (in points) of a given substring in the
    ///     resolved glyph metrics. Injected so this is deterministic in tests.
    public static func layout(
        caretRect: CGRect,
        fieldBounds: CGRect,
        metrics: GhostTextMetrics,
        maxLines: Int = 3,
        candidate: String,
        measure: (String) -> CGFloat
    ) -> Result {
        let lineHeight = max(metrics.lineHeight, 1)
        let fieldMinX = fieldBounds.minX
        let fieldMaxX = fieldBounds.maxX
        let fieldWidth = max(fieldBounds.width, 0)
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
                // field's leading edge (drop trailing spaces before this break).
                lines.append(Line(
                    text: trimTrailingWhitespace(current),
                    xOffset: currentLeftX - fieldMinX
                ))
                current = ""
                firstLine = false
                currentLeftX = fieldMinX

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
                    fieldWidth: fieldWidth
                ) {
                    current = proposed
                } else {
                    // Soft wrap at a word boundary: flush the line, dropping the
                    // trailing whitespace, and start the next line at the leading edge.
                    lines.append(Line(
                        text: trimTrailingWhitespace(current),
                        xOffset: currentLeftX - fieldMinX
                    ))
                    current = chunk.text
                    firstLine = false
                    currentLeftX = fieldMinX
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
        fieldWidth: CGFloat
    ) -> CGFloat {
        // On the caret line the text may only run to the field's trailing edge;
        // wrapped lines get the full field width from the leading edge.
        firstLine ? max(fieldMaxX - currentLeftX, 0) : fieldWidth
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
