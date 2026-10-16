import Foundation

/// The canonical output sanitizer shared by the app engine and the eval.
///
/// Cotype prompts a local model to "return only the continuation", but
/// instruction-tuned models still reproduce the prompt prefix, leak Gemma
/// control/turn/channel markers across token boundaries, or emit template
/// delimiters. This type owns a single, deterministic definition of:
///
///  - what counts as forbidden output (control tokens, structural channel/tool
///    markers, turn delimiters, stop sequences),
///  - how a genuine prompt **echo** is removed without over-stripping a
///    continuation that happens to match the prompt tail,
///  - when a completion should be treated as **no suggestion** (nothing valid
///    was produced) rather than a degenerate empty generation.
///
/// `CompletionPipeline` runs `sanitize(_:promptTail:)` over every engine result,
/// so the menu app and the eval share one definition. `StreamingOutputGuard`
/// (below) uses the *same* configured token sets so an in-process engine can
/// hold back partial delimiters during streaming without diverging.
public struct OutputSanitizer {

    public struct Config {
        /// Gemma 4 turn delimiters and template markers that must never appear
        /// in a completion. Generation cuts at the earliest one.
        public static let gemmaControlTokens: [String] = [
            "<|turn>", "<turn|>", "</text-after-cursor>", "<|end>",
        ]

        /// Channel / tool / thought / multimodal markers. If emitted, the marker
        /// itself is dropped (never shown) but generation may continue.
        public static let gemmaStructuralPrefixes: [String] = [
            "<|channel", "<channel", "<|tool", "<tool", "<|think",
            "<|image", "<|audio", "<|\"",
        ]

        /// Default stop sequences passed to an engine; also cut on here.
        public static let defaultStopSequences: [String] = ["\n\n", "```"]

        /// Control tokens / template markers that cut and stop generation.
        public var controlTokens: [String]

        /// Channel / tool markers that are dropped but do not stop generation.
        public var structuralPrefixes: [String]

        /// Stop sequences that cut and stop generation.
        public var stopSequences: [String]

        /// A prompt echo is only stripped once it is at least this long, so a
        /// short overlap that is genuinely part of the continuation is preserved.
        public var minEchoLength: Int

        public init(
            controlTokens: [String] = Config.gemmaControlTokens,
            structuralPrefixes: [String] = Config.gemmaStructuralPrefixes,
            stopSequences: [String] = Config.defaultStopSequences,
            minEchoLength: Int = 12
        ) {
            self.controlTokens = controlTokens
            self.structuralPrefixes = structuralPrefixes
            self.stopSequences = stopSequences
            self.minEchoLength = minEchoLength
        }

        /// The canonical Gemma configuration used everywhere.
        public static let gemma = Config()
    }

    /// Everything that cuts generation: control tokens plus stop sequences.
    private var cutTokens: [String] { config.controlTokens + config.stopSequences }

    public let config: Config

    public init(config: Config = .gemma) {
        self.config = config
    }

    /// The outcome of sanitizing one generated string.
    public struct Result {
        /// The cleaned text to show/insert. Empty means "no suggestion".
        public let text: String
        /// True when sanitization produced nothing usable. The caller should
        /// treat this as an explicit abstain (`.noSuggestion`), not a failure.
        public let isNoSuggestion: Bool

        public init(text: String, isNoSuggestion: Bool) {
            self.text = text
            self.isNoSuggestion = isNoSuggestion
        }
    }

    /// Sanitize a fully-assembled generation.
    ///
    /// - Parameters:
    ///   - raw: the engine's output (may include echo, control tokens).
    ///   - promptTail: the trailing input context used to detect prompt echo.
    private func sanitize(_ raw: String, promptTail: String) -> String {
        guard !raw.isEmpty else { return "" }

        // 1. Drop structural channel/tool markers (and the tag they open) so
        //    control text never survives even if it was emitted as plain text.
        var text = Self.dropStructuralTags(raw, prefixes: config.structuralPrefixes)

        // 2. Cut at the earliest complete control token or stop sequence. The
        //    completion never includes a turn/channel delimiter it invented.
        text = Self.cutAtEarliest(text, tokens: cutTokens)

        // 3. Drop a trailing partial control token that never completed (e.g. a
        //    model streamed `<|turn` but lost the final `>`). Never drop a
        //    partial stop sequence here, since that can be legitimate content.
        text = Self.dropTrailingPartial(text, prefixes: config.controlTokens + config.structuralPrefixes)

        // 4. Remove a genuine prompt echo without over-stripping a short overlap
        //    that is really the continuation.
        text = Self.stripPromptEcho(text, promptTail: promptTail, minEchoLength: config.minEchoLength)

        // 5. Trim to a presentable, insertable string, preserving a meaningful
        //    leading boundary (word space / line break / indentation) and only
        //    dropping the leading separator the prompt tail already supplies.
        return Self.trimForInsertion(text, promptTail: promptTail)
    }

    public func process(_ raw: String, promptTail: String, suffix: String? = nil) -> Result {
        // An exact raw reproduction (or a reproduction that differs only by
        // surrounding whitespace, e.g. a trailing "\n" Gemma artifact) is
        // unambiguously an echo even when short. Check before cutting control
        // tokens so a useful completion followed by a stop marker is not
        // mistaken for an echo. A genuine continuation is never the whole
        // prompt tail after trimming, so this never over-strips.
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTail = promptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw == promptTail || (!trimmedRaw.isEmpty && trimmedRaw == trimmedTail) {
            return Result(text: "", isNoSuggestion: true)
        }
        // Some models reproduce markup while collapsing its formatting (for
        // example `</body>\n</html>` -> `</body></html>`). Treat a sufficiently
        // long whitespace-insensitive full echo as no suggestion.
        let compactRaw = Self.removingWhitespace(trimmedRaw)
        let compactTail = Self.removingWhitespace(trimmedTail)
        if compactRaw.count >= config.minEchoLength, compactRaw == compactTail {
            return Result(text: "", isNoSuggestion: true)
        }

        var text = sanitize(raw, promptTail: promptTail)
        text = Self.stripRepeatedTerminalCodeKeyword(text, promptTail: promptTail)
        text = Self.stripRepeatedTerminalWord(text, promptTail: promptTail)
        text = Self.cutAtUnbalancedCloser(text, promptTail: promptTail)

        if let suffix, !suffix.isEmpty {
            // If prefix+suffix already form exactly what the model regenerated,
            // there is no missing text at the cursor.
            if Self.isBoundaryRecomposition(text, promptTail: promptTail, suffix: suffix) {
                return Result(text: "", isNoSuggestion: true)
            }
            // Chat models often include the beginning of the supplied suffix in
            // their answer. Remove only an exact trailing-output/leading-suffix
            // overlap; the suffix is already present in the document.
            text = Self.stripDuplicatedSuffixPrefix(text, suffix: suffix)
            text = Self.trimForInsertion(text, promptTail: promptTail)
        }
        return Result(text: text, isNoSuggestion: text.isEmpty)
    }

    /// True when text appended to `raw` can no longer change what `process`
    /// keeps from `raw`, so a caller may stop generating once the candidate
    /// rules (sentence end, word cap) have also decided.
    ///
    /// Most steps cut at a position and keep what came before it. Five things
    /// still depend on text not yet generated, and each keeps the stream
    /// running:
    /// - `raw` ends with the start of a cut token or tag (a lone "<" or "`"):
    ///   completing it would cut the end off, and a shorter end can match the
    ///   start of the suffix and be removed as a duplicate.
    /// - An open structural tag can still close and remove text shown now.
    /// - The output so far is a prefix of the prompt tail: it can still grow
    ///   into a whole-tail echo.
    /// - The output so far sits inside the prompt tail: it can still grow into
    ///   a longer partial echo.
    /// - The output repeats the field's last word and no second word has
    ///   begun, so the repeated-word rule has not decided yet.
    public func isSettled(_ raw: String, promptTail: String) -> Bool {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return false }
        if config.structuralPrefixes.contains(where: { !$0.isEmpty && raw.contains($0) }) {
            return false
        }
        let body = Self.cutAtEarliest(raw, tokens: cutTokens)
        if body.count == raw.count {
            let pending = cutTokens + config.structuralPrefixes
            for length in 1...min(raw.count, pending.map(\.count).max() ?? 0) {
                let end = String(raw.suffix(length))
                if pending.contains(where: { $0.hasPrefix(end) }) { return false }
            }
        }
        let trimmedTail = promptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTail.hasPrefix(trimmedRaw) { return false }
        if Self.removingWhitespace(trimmedTail).hasPrefix(Self.removingWhitespace(trimmedRaw)) {
            return false
        }
        // The text the echo rule compares with the tail.
        if !body.isEmpty, promptTail.contains(body) { return false }
        // The repeated-boundary-word rule waits for a second word.
        let text = Self.stripRepeatedTerminalCodeKeyword(
            sanitize(raw, promptTail: promptTail),
            promptTail: promptTail
        )
        return !Self.repeatedTerminalWordIsPending(text, promptTail: promptTail)
    }

    // MARK: - Forbidden-output detection (used by the eval, not by sanitizing)

    /// Whether a string contains any known forbidden output: control tokens,
    /// structural channel/tool markers, or invented turn delimiters. The eval
    /// uses this to score `forbiddenOutput` independently of what the sanitizer
    /// repaired, so a leak is still measurable.
    public static func containsForbidden(_ text: String) -> Bool {
        return Config.gemmaControlTokens.contains { text.contains($0) }
            || Config.gemmaStructuralPrefixes.contains { text.contains($0) }
    }

    // MARK: - Boundary-whitespace handling

    /// Final presentation trim.
    ///
    /// A blanket `trimmingCharacters(.whitespacesAndNewlines)` drops *leading*
    /// whitespace, which merges a completion into the preceding word when the
    /// prompt tail does not already end in whitespace ("hello" + " world" becomes
    /// "helloworld", and a leading-space ghost cannot be shown for type-through).
    ///
    /// This preserves a leading boundary rather than always stripping it, and
    /// only drops a leading separator when the prompt tail already supplies it:
    ///  - Prompt tail does **not** end in whitespace: the candidate's leading
    ///    space/newline/indentation is a genuine boundary and is preserved.
    ///  - Prompt tail ends in whitespace: drop the leading whitespace that would
    ///    merely duplicate it (a double space, or a blank line), but keep any
    ///    indentation that follows a line break.
    ///
    /// A candidate that is only whitespace yields an empty result.
    static func trimForInsertion(_ text: String, promptTail: String) -> String {
        guard !text.isEmpty else { return "" }

        // Trailing whitespace is never useful; strip it from the end only.
        var body = text
        while let last = body.last, last.isWhitespace {
            body.removeLast()
        }
        guard !body.isEmpty else { return "" }

        let head = body.prefix { $0.isWhitespace }
        let content = String(body.dropFirst(head.count))
        guard !content.isEmpty else { return "" }

        // If the prompt tail does not end in whitespace, the leading boundary is
        // meaningful (a word break, a line break, or indentation): preserve it.
        guard let lastTail = promptTail.last, lastTail.isWhitespace else {
            return String(head) + content
        }

        // The prompt tail already ends in whitespace. Avoid doubling the
        // separator it supplies, but preserve structure (indentation after a
        // line break, or a line break after a trailing space).
        let headStr = String(head)
        if lastTail.isNewline {
            return String(headStr.drop(while: { $0.isNewline })) + content
        } else {
            return String(headStr.drop(while: { $0 == " " || $0 == "\t" })) + content
        }
    }

    // MARK: - Pure string helpers

    /// Drop complete structural tags (a structural prefix plus everything up to
    /// and including the next `>`, bounded to avoid eating the whole document).
    static func dropStructuralTags(_ text: String, prefixes: [String]) -> String {
        guard !prefixes.isEmpty else { return text }
        var result = text
        var searchStart = result.startIndex
        // Process repeatedly; removing tags shifts indices.
        while searchStart < result.endIndex {
            let searchRange = searchStart..<result.endIndex
            var earliest: Range<String.Index>?
            for prefix in prefixes where !prefix.isEmpty {
                if let r = result.range(of: prefix, range: searchRange) {
                    if earliest == nil || r.lowerBound < earliest!.lowerBound {
                        earliest = r
                    }
                }
            }
            guard let tagRange = earliest else { break }
            // Extend through the closing '>' (or a bounded window if none).
            var end = tagRange.upperBound
            var scan = tagRange.upperBound
            var hops = 0
            while scan < result.endIndex, hops < 64 {
                let c = result[scan]
                scan = result.index(after: scan)
                hops += 1
                if c == ">" {
                    end = scan
                    break
                }
            }
            result.removeSubrange(tagRange.lowerBound..<end)
            searchStart = tagRange.lowerBound
        }
        return result
    }

    /// Return the substring before the earliest occurrence of any cut token.
    static func cutAtEarliest(_ text: String, tokens: [String]) -> String {
        guard !tokens.isEmpty, !text.isEmpty else { return text }
        var earliest = text.endIndex
        for token in tokens where !token.isEmpty {
            if let r = text.range(of: token), r.lowerBound < earliest {
                earliest = r.lowerBound
            }
        }
        return earliest == text.endIndex ? text : String(text[..<earliest])
    }

    /// Remove a suffix that is a *prefix* of a forbidden control/structural
    /// token but did not complete (e.g. a trailing `<|tur`).
    ///
    /// Two guardrails prevent over-stripping ordinary text:
    ///  - A minimum partial length (default 2) so a lone trailing `<` in code
    ///    (a `< b`, a generic `<T`) is never dropped. Only a real control
    ///    precursor like `<|` or `<t` is removed.
    ///  - Stop sequences are excluded entirely: a lone `\n` before `\n\n` is
    ///    legitimate content and is preserved.
    static func dropTrailingPartial(_ text: String, prefixes: [String], minPartialLength: Int = 2) -> String {
        guard !prefixes.isEmpty, !text.isEmpty else { return text }
        let nonEmpty = prefixes.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return text }
        let maxPrefix = nonEmpty.map(\.count).max() ?? 0
        let maxScan = min(text.count, maxPrefix)
        guard maxScan >= minPartialLength else { return text }
        var longest = 0
        for len in stride(from: maxScan, through: minPartialLength, by: -1) {
            let suffix = String(text.suffix(len))
            if nonEmpty.contains(where: { $0.hasPrefix(suffix) }) {
                longest = len
                break
            }
        }
        return longest == 0 ? text : String(text.dropLast(longest))
    }

    /// Remove a prompt echo: the longest prefix of `output` that equals a suffix
    /// of `promptTail`, provided that overlap is unambiguous (>= `minEchoLength`).
    ///
    /// This deliberately improves on a naive "strip the longest tail overlap":
    /// a short overlap (a variable name, a closing brace, a common word) is
    /// usually part of the genuine continuation and is preserved.
    static func stripPromptEcho(_ output: String, promptTail: String, minEchoLength: Int) -> String {
        guard !output.isEmpty, !promptTail.isEmpty else { return output }
        let upper = min(output.count, promptTail.count)
        guard upper >= minEchoLength else { return output }
        let outputChars = Array(output)
        let tailChars = Array(promptTail)
        var overlap = 0
        for index in stride(from: upper, through: 1, by: -1) {
            // output.prefix(index) == promptTail.suffix(index)
            if outputChars[0..<index].elementsEqual(tailChars[(tailChars.count - index)..<tailChars.count]) {
                overlap = index
                break
            }
        }
        guard overlap >= minEchoLength else { return output }
        return String(outputChars.dropFirst(overlap))
    }

    private static func removingWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// Remove a duplicated code keyword when the cursor is already after that
    /// keyword (`throw ` + `throw Error()` -> `Error()`). Restricting this to a
    /// small syntax-keyword set avoids changing legitimate prose repetition.
    static func stripRepeatedTerminalCodeKeyword(_ output: String, promptTail: String) -> String {
        let keywords: Set<String> = [
            "return", "throw", "let", "var", "const", "func", "class",
            "struct", "if", "else", "for", "while", "guard", "case",
        ]
        let trimmedTail = promptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyword = trimmedTail.split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
              keywords.contains(keyword),
              output == keyword || output.hasPrefix(keyword + " ") || output.hasPrefix(keyword + "\t")
        else { return output }
        return String(output.dropFirst(keyword.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove a repeated word at the field/candidate boundary when the model
    /// continues beyond it (`Regarding order ` + `order number AX-2048`). Require
    /// another word after the repetition so intentional single-word emphasis is
    /// left alone.
    static func stripRepeatedTerminalWord(_ output: String, promptTail: String) -> String {
        guard let remainder = repeatedTerminalWordRemainder(output, promptTail: promptTail),
              remainder.contains(where: { $0.isWhitespace })
        else { return output }
        return remainder
    }

    /// True when `output` repeats the field's last word but the rule above
    /// still waits for another word before it strips the repetition.
    static func repeatedTerminalWordIsPending(_ output: String, promptTail: String) -> Bool {
        guard let remainder = repeatedTerminalWordRemainder(output, promptTail: promptTail) else { return false }
        return !remainder.contains(where: { $0.isWhitespace })
    }

    /// The text after a repeated boundary word, or nil when there is none.
    private static func repeatedTerminalWordRemainder(_ output: String, promptTail: String) -> String? {
        guard promptTail.last?.isWhitespace == true else { return nil }
        let trimmedTail = promptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let terminal = trimmedTail.split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
              terminal.count >= 4,
              output.lowercased().hasPrefix(terminal.lowercased() + " ")
        else { return nil }
        return String(output.dropFirst(terminal.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cut the candidate before the first closing bracket that nothing open
    /// in the prefix or the candidate matches (`](https://github.com/` +
    /// `name/repo)),` -> `name/repo)`). A suggestion never closes more than the
    /// author opened. Brackets are counted over the whole prompt tail; quotes
    /// are not tracked, so this only ever shortens a candidate.
    static func cutAtUnbalancedCloser(_ output: String, promptTail: String) -> String {
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        let openers: Set<Character> = ["(", "[", "{"]
        var stack: [Character] = []
        for c in promptTail {
            if openers.contains(c) {
                stack.append(c)
            } else if let open = pairs[c], stack.last == open {
                stack.removeLast()
            }
        }
        for index in output.indices {
            let c = output[index]
            if openers.contains(c) {
                stack.append(c)
            } else if let open = pairs[c] {
                guard stack.last == open else {
                    var kept = String(output[..<index])
                    while let last = kept.last, last.isWhitespace { kept.removeLast() }
                    return kept
                }
                stack.removeLast()
            }
        }
        return output
    }

    /// True when the model output merely regenerates text that is already formed
    /// by the partial identifier before the cursor plus the supplied suffix.
    static func isBoundaryRecomposition(_ output: String, promptTail: String, suffix: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let partial = String(promptTail.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
        guard !partial.isEmpty else { return false }
        let alreadyPresent = partial + suffix
        return alreadyPresent.hasPrefix(trimmed)
    }

    /// Remove the longest exact overlap between the end of generated output and
    /// the start of text already present after the cursor.
    static func stripDuplicatedSuffixPrefix(_ output: String, suffix: String) -> String {
        guard !output.isEmpty, !suffix.isEmpty else { return output }
        let upper = min(output.count, suffix.count)
        guard upper > 0 else { return output }
        for length in stride(from: upper, through: 1, by: -1) {
            if output.suffix(length) == suffix.prefix(length) {
                return String(output.dropLast(length))
            }
        }
        return output
    }
}

/// A streaming boundary guard used by an in-process engine so a partial
/// delimiter never reaches the renderer before it resolves.
///
/// The engine streams token pieces; this guard holds back a tail as long as the
/// longest forbidden boundary, so a control token (`<|turn`) or a stop sequence
/// (`\n\n`) split across tokens is never partially emitted. It slots into the
/// generation loop:
///
/// ```swift
/// let emitted = guard.append(cleanPiece)
/// if !emitted.isEmpty { onToken(emitted) }
/// if guard.isStopped { break }
/// ```
///
/// It uses the *same* token sets as `OutputSanitizer`, so the in-process stream
/// and the whole-string sanitizer agree on what is invalid.
public struct StreamingOutputGuard {

    /// Control tokens that both cut generation and must never leak a partial.
    private let controlTokens: [String]
    /// Token set checked for a *complete* match (control tokens + stop sequences).
    private let cutTokens: [String]
    private let dropPrefixes: [String]
    private let maxBoundary: Int

    private var buffer = ""
    private(set) public var isStopped = false

    public init(config: OutputSanitizer.Config = .gemma) {
        self.controlTokens = config.controlTokens
        self.cutTokens = config.controlTokens + config.stopSequences
        self.dropPrefixes = config.structuralPrefixes
        let boundary = (self.cutTokens + self.dropPrefixes)
            .filter { !$0.isEmpty }
            .map { $0.count }
            .max() ?? 0
        self.maxBoundary = boundary
    }

    /// Feed one piece of clean generated text. Returns the portion safe to emit
    /// now. Once `isStopped` is true, the caller should stop generation.
    public mutating func append(_ piece: String) -> String {
        guard !isStopped else { return "" }
        buffer += piece
        return drain()
    }

    /// Flush any remaining safe text when generation ends naturally. A trailing
    /// partial forbidden token is dropped rather than emitted.
    public mutating func finish() -> String {
        defer { isStopped = true }
        return drain(flushing: true)
    }

    private mutating func drain(flushing: Bool = false) -> String {
        var emitted = ""

        while !buffer.isEmpty {
            // 1. A complete control token / stop sequence: cut and stop.
            if let earliest = earliestCutMatch() {
                // Emit the safe text before the match, after dropping any
                // structural tags that precede it.
                let safe = OutputSanitizer.dropStructuralTags(
                    String(buffer[..<earliest]),
                    prefixes: dropPrefixes
                )
                emitted += safe
                isStopped = true
                buffer.removeAll(keepingCapacity: true)
                return emitted
            }

            // 2. A complete structural tag: drop it (and the tag it opens).
            if let dropRange = earliestDropMatch() {
                buffer.removeSubrange(dropRange)
                if buffer.isEmpty { break }
                continue
            }

            // 3. No complete match. Emit only the front that cannot start a
            //    forbidden token. When flushing, also drop a trailing partial
            //    control token.
            if flushing {
                emitted += OutputSanitizer.dropTrailingPartial(
                    buffer,
                    prefixes: controlTokens + dropPrefixes
                )
                buffer.removeAll(keepingCapacity: true)
                break
            }

            if maxBoundary > 0 && buffer.count > maxBoundary {
                let emitCount = buffer.count - maxBoundary
                emitted += String(buffer.prefix(emitCount))
                buffer.removeFirst(emitCount)
            } else {
                break
            }
        }

        return emitted
    }

    private func earliestCutMatch() -> String.Index? {
        var earliest: String.Index?
        for token in cutTokens where !token.isEmpty {
            if let r = buffer.range(of: token) {
                if earliest == nil || r.lowerBound < earliest! {
                    earliest = r.lowerBound
                }
            }
        }
        return earliest
    }

    private func earliestDropMatch() -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for prefix in dropPrefixes where !prefix.isEmpty {
            if let r = buffer.range(of: prefix) {
                if earliest == nil || r.lowerBound < earliest!.lowerBound {
                    earliest = r
                }
            }
        }
        guard let tagStart = earliest else { return nil }
        var end = tagStart.upperBound
        var scan = tagStart.upperBound
        var hops = 0
        while scan < buffer.endIndex, hops < 64 {
            let c = buffer[scan]
            scan = buffer.index(after: scan)
            hops += 1
            if c == ">" {
                end = scan
                break
            }
        }
        return tagStart.lowerBound..<end
    }
}
