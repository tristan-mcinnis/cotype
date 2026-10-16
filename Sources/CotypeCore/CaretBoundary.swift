import Foundation

/// Joins a model continuation onto the text before the caret.
///
/// Chat models drop the leading space ("...back to you by" -> "the end", which
/// would insert "bythe end") and often restate the partial word they were given
/// ("any questi" -> "questions"). All three reference apps reconcile this on
/// the output side (KeyType `CaretBoundary`, TabType `reconcileMidWord`,
/// cotabby `insertionChunk`). The rules, in order:
///
/// 1. Strip a leading "Output:" scaffold echo.
/// 2. Caret after whitespace: drop the candidate's leading whitespace.
/// 3. Caret mid-word and the candidate restates that word: keep only the rest.
/// 4. Caret mid-word, candidate starts a letter with no space: join the word
///    if the joined word is real, otherwise add a space when the typed word is
///    already complete.
/// 5. Caret after sentence punctuation and the candidate starts a word: add a
///    space.
///
/// `isWord` answers "is this a correctly spelled word?" and is injected so the
/// rules stay pure and testable; the app passes the system spell checker.
public enum CaretBoundary {

    /// - Parameter modelSawBoundary: true when the model continued the exact
    ///   text (plain-text continuation), so it already chose whether a space
    ///   follows; rules 4 and 5 would then break `3pm`, `res.json()`, `e.g.`.
    public static func reconcile(
        prefix: String,
        candidate: String,
        isWord: ((String) -> Bool)? = nil,
        modelSawBoundary: Bool = false
    ) -> String {
        var text = candidate
        if let range = text.range(of: "Output:"), text[..<range.lowerBound].allSatisfy(\.isWhitespace) {
            text = String(text[range.upperBound...])
            if text.first == " " { text.removeFirst() }
        }
        guard !text.isEmpty, let last = prefix.last else { return text }

        if last.isWhitespace {
            return String(text.drop(while: \.isWhitespace))
        }

        let partial = trailingWord(of: prefix)
        guard let first = text.first, !first.isWhitespace else { return text }

        if !partial.isEmpty, isSpacedScript(partial) {
            // Rule 3: the model restated the partial word.
            if text.count > partial.count,
               text.lowercased().hasPrefix(partial.lowercased()) {
                return String(text.dropFirst(partial.count))
            }
            // Rule 4: continuation or new word? A model that continued the
            // exact text already chose ("3" + "pm", "questi" + "ons").
            if !modelSawBoundary, first.isLetter, isSpacedScript(String(first)) {
                let head = leadingWord(of: text)
                guard let isWord else { return text }
                let partialIsWord = isWord(partial)
                let joinedIsWord = isWord(partial + head)
                if joinedIsWord && !partialIsWord { return text }
                if partialIsWord && !joinedIsWord { return " " + text }
                return text
            }
            return text
        }

        // Rule 5.
        if !modelSawBoundary, ".,;:!?)".contains(last), first.isLetter || first.isNumber, isSpacedScript(String(first)) {
            return " " + text
        }
        return text
    }

    /// True when the caret sits inside a word that text after it already
    /// continues ("wid|th"). Nothing useful fits there, so the pipeline abstains
    /// instead of asking the model. Spaced scripts only: in CJK text every
    /// position is "inside a word" and insertion mid-sentence is normal.
    public static func isInsideWord(prefix: String, suffix: String) -> Bool {
        guard let before = prefix.last, let after = suffix.first else { return false }
        func isWordChar(_ c: Character) -> Bool {
            (c.isLetter || c.isNumber || c == "_") && isSpacedScript(String(c))
        }
        return isWordChar(before) && isWordChar(after)
    }

    /// Keep a suggestion inside the current sentence: cut after the first
    /// sentence end (`.`, `!`, `?` followed by whitespace, or a CJK full stop),
    /// and suggest nothing when the caret sits right after a sentence end and
    /// the candidate would open the next sentence ("The end." + " It was").
    /// The next sentence gets its own suggestion once the author types a space.
    public static func limitToSentence(prefix: String, candidate: String) -> String {
        if let last = prefix.last, ".!?".contains(last),
           let first = candidate.first, first.isWhitespace {
            return ""
        }
        var index = candidate.startIndex
        while index < candidate.endIndex {
            let c = candidate[index]
            let next = candidate.index(after: index)
            if "。！？".contains(c) { return String(candidate[..<next]) }
            if ".!?".contains(c), next < candidate.endIndex, candidate[next].isWhitespace {
                return String(candidate[..<next])
            }
            index = next
        }
        return candidate
    }

    /// Letters and digits immediately before the caret.
    static func trailingWord(of text: String) -> String {
        String(text.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" }.reversed())
    }

    static func leadingWord(of text: String) -> String {
        String(text.prefix { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    /// Scripts that separate words with spaces. CJK, Thai, and similar scripts
    /// never get a synthesized space.
    static func isSpacedScript(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF,          // Thai, Lao
                 0x1000...0x109F,          // Myanmar
                 0x1780...0x17FF,          // Khmer
                 0x3040...0x30FF,          // Hiragana, Katakana
                 0x3400...0x4DBF,          // CJK Extension A
                 0x4E00...0x9FFF,          // CJK Unified
                 0xAC00...0xD7AF,          // Hangul
                 0xF900...0xFAFF,          // CJK Compatibility
                 0xFF00...0xFFEF:          // Full-width forms
                return false
            default:
                return true
            }
        }
    }
}
