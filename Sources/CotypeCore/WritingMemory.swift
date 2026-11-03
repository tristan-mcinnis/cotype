import Foundation

/// What Cotype keeps of the author's own writing, and which of it each prompt
/// shows the model.
///
/// Measured on 2026-11-04 with gemma-4-E2B-it. Showing past writing doubled
/// next-word hits on 22 real samples (4 to 8-9) and cut invented stock topics
/// ("the Q3 report") from 12 of 20 synthetic cases to 4. A list of favourite
/// words raised vocabulary fit further, but pushed work terms into 6 of 10
/// unrelated sentences, so the model gets sentences only.
public enum WritingMemory {
    static let maxExamples = 5
    static let maxExampleChars = 90
    static let minWords = 4
    static let maxPieceChars = 200
    static let readChars = 1000
    /// Oldest writing is dropped past this, keeping the file and each scan small.
    public static let maxKept = 400

    /// The sentences in `prefix` worth keeping. The sentence still being typed
    /// counts once it has enough words, less its last word, which may be partial.
    public static func pieces(of prefix: String) -> [String] {
        let bounded = String(prefix.suffix(readChars))
        guard !TextKind.looksLikeCode(bounded) else { return [] }
        var pieces: [String] = []
        var current = ""
        var isFinished = false
        for character in bounded {
            if character.isNewline || "。！？".contains(character) {
                if !character.isNewline { current.append(character) }
                pieces.append(current)
                current = ""
                isFinished = false
                continue
            }
            if isFinished, character.isWhitespace {
                pieces.append(current)
                current = ""
                isFinished = false
                continue
            }
            current.append(character)
            isFinished = ".!?".contains(character)
        }
        if isFinished {
            pieces.append(current)
        } else if bounded.last?.isWhitespace == true {
            pieces.append(current)
        } else if let lastSpace = current.lastIndex(where: \.isWhitespace) {
            pieces.append(String(current[..<lastSpace]))
        }
        // A bounded read can start inside a sentence.
        if bounded.count < prefix.count, !pieces.isEmpty { pieces.removeFirst() }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isWorthKeeping)
    }

    /// Up to `maxExamples` lines of past writing for this text: those sharing the
    /// most words with it first, this app's next, then the newest. Text already
    /// in `prefix` is skipped, since the model has it, and so is writing in
    /// another script, which pulls the model out of the language in use.
    public static func examples(
        from samples: [PersonalizationSample],
        prefix: String,
        appIdentifier: String
    ) -> [String] {
        let context = String(prefix.suffix(200))
        guard !TextKind.looksLikeCode(prefix) else { return [] }
        let wanted = significantWords(of: context)
        let wantsUnspaced = !CaretBoundary.isSpacedScript(context)

        var seen = Set<String>()
        var ranked: [(text: String, score: Int)] = []
        for sample in samples {
            guard let text = text(of: sample), isWorthKeeping(text),
                  CaretBoundary.isSpacedScript(text) != wantsUnspaced,
                  !prefix.contains(text),
                  seen.insert(text.lowercased()).inserted
            else { continue }
            let shared = wanted.intersection(significantWords(of: text)).count
            ranked.append((text, shared * 2 + (sample.appIdentifier == appIdentifier ? 1 : 0)))
        }
        // `sorted` is not stable; the offset keeps the newest first within a score.
        return ranked.enumerated()
            .sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }
            .prefix(maxExamples)
            .map { tail(of: $0.element.text) }
    }

    private static func text(of sample: PersonalizationSample) -> String? {
        switch sample.outcome {
        case .written:
            return sample.prefix
        case .accepted:
            let line = (sample.prefix + sample.completion)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return line.trimmingCharacters(in: .whitespaces)
        case .shown, .dismissed, .canceled, .failed:
            return nil
        }
    }

    /// Long enough to show a voice, and free of what must not be repeated
    /// elsewhere: addresses, links, and long numbers.
    private static func isWorthKeeping(_ text: String) -> Bool {
        guard text.count <= maxPieceChars, !TextKind.looksLikeCode(text) else { return false }
        let enough = CaretBoundary.isSpacedScript(text)
            ? text.split(whereSeparator: \.isWhitespace).count >= minWords
            : text.count >= minWords * 2
        guard enough, !text.contains("@"), !text.contains("://") else { return false }
        return text.range(of: #"\d{6,}"#, options: .regularExpression) == nil
    }

    private static func significantWords(of text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        return Set(words.flatMap { word -> [String] in
            guard CaretBoundary.isSpacedScript(word) else {
                // Unspaced scripts have no word breaks: compare pairs of characters.
                let characters = Array(word)
                return characters.indices.dropLast().map { String(characters[$0...($0 + 1)]) }
            }
            return ContinuationPrompt.finishedWords.contains(word) ? [] : [word]
        })
    }

    private static func tail(of text: String) -> String {
        guard text.count > maxExampleChars else { return text }
        let cut = text.suffix(maxExampleChars)
        guard CaretBoundary.isSpacedScript(String(cut)), let space = cut.firstIndex(where: \.isWhitespace) else {
            return String(cut)
        }
        return String(cut[cut.index(after: space)...])
    }
}
