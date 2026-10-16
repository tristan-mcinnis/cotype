import Foundation

/// Enforces Cotype's deliberately narrow product contract: suggest only the
/// next few words, never continue writing a paragraph. "Word" here means one
/// whitespace-delimited insertion unit, which also behaves predictably for code
/// (`a + b` is three units) and preserves punctuation attached to a word.
public enum SuggestionWordLimiter {
    public static func limit(_ text: String, maxWords: Int = 4) -> String {
        guard maxWords > 0, !text.isEmpty else { return "" }
        var words = 0
        var insideWord = false
        var cut: String.Index?

        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                insideWord = false
                continue
            }
            if !insideWord {
                words += 1
                if words > maxWords {
                    cut = index
                    break
                }
                insideWord = true
            }
        }

        var result = cut.map { String(text[..<$0]) } ?? text
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    /// True when `text` has begun a word past the cap, so `limit` cuts it and
    /// no later text can change the result.
    public static func exceedsLimit(_ text: String, maxWords: Int) -> Bool {
        var words = 0
        var insideWord = false
        for character in text {
            if character.isWhitespace {
                insideWord = false
            } else if !insideWord {
                words += 1
                if words > maxWords { return true }
                insideWord = true
            }
        }
        return false
    }
}
