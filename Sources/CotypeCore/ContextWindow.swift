import Foundation

/// Bounds the captured text context to a window nearest the caret.
///
/// A completion prompt is only as good as the text immediately before the
/// cursor. A long document's early lines carry no signal for what belongs right
/// after the caret, and a huge prefix both wastes the (finite) llama.cpp context
/// and risks drowning out the Gemma system/user/model header structure. This
/// type keeps the trailing `maxChars` of a prefix and drops the far-from-caret
/// head, so the prompt always reflects the text nearest the insertion point.
public enum ContextWindow {

    /// Returns the trailing `maxChars` characters of `prefix` — the text nearest
    /// the caret (the end of the prefix). A prefix no longer than `maxChars` is
    /// returned unchanged. `maxChars <= 0` yields an empty string.
    public static func nearestCaret(prefix: String, maxChars: Int) -> String {
        guard maxChars > 0, !prefix.isEmpty else { return "" }
        guard prefix.count > maxChars else { return prefix }
        // Always keep a whole trailing window; drop the leading document text.
        return String(prefix.suffix(maxChars))
    }

    /// Returns the leading `maxChars` characters of `suffix` — the text nearest
    /// the caret (the start of the suffix, i.e. immediately after the cursor). A
    /// suffix no longer than `maxChars` is returned unchanged; the far-from-caret
    /// trailing text is dropped, so a huge document suffix never overflows the
    /// context.
    public static func nearestCaretSuffix(_ suffix: String, maxChars: Int) -> String {
        guard maxChars > 0, !suffix.isEmpty else { return "" }
        guard suffix.count > maxChars else { return suffix }
        return String(suffix.prefix(maxChars))
    }
}
