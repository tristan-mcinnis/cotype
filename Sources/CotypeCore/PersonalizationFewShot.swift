import Foundation

/// Builds the bounded, privacy-conscious "Learn from accepted completions"
/// few-shot summary that `TemplatePromptBuilder` injects into the prompt when
/// the user has opted in.
///
/// Truthfulness and privacy guarding:
///  - Only `.accepted` samples are training signal (dismissals, cancels, and
///    failures carry a different semantics and are never used as few-shot
///    examples).
///  - Each sample's prefix and completion are truncated to hard per-field
///    bounds and collapsed to a single line, so a full document or a large code
///    block is never lifted verbatim into the prompt.
///  - At most `maxSamples` examples are included, and the whole summary is
///    capped at `maxTotalChars`, so a large backlog never blows the context.
public enum PersonalizationFewShot {

    /// Hard bounds applied when building the summary.
    public struct Bounds: Equatable, Sendable {
        public var maxSamples: Int
        public var maxPrefixChars: Int
        public var maxCompletionChars: Int
        public var maxTotalChars: Int

        public init(maxSamples: Int, maxPrefixChars: Int, maxCompletionChars: Int, maxTotalChars: Int) {
            self.maxSamples = maxSamples
            self.maxPrefixChars = maxPrefixChars
            self.maxCompletionChars = maxCompletionChars
            self.maxTotalChars = maxTotalChars
        }

        /// Defaults: a handful of short examples, never a document dump.
        public static let `default` = Bounds(
            maxSamples: 3,
            maxPrefixChars: 120,
            maxCompletionChars: 120,
            maxTotalChars: 600
        )
    }

    /// A newline-free, whitespace-collapsed single-line rendering of raw context,
    /// used so multi-line document text becomes a compact, prompt-safe example.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Build the bounded few-shot summary from accepted samples.
    ///
    /// - Parameters:
    ///   - samples: recorded completion samples.
    ///   - filterApp: when non-nil, only that app's samples are used.
    ///   - bounds: the per-field and total caps.
    /// - Returns: a bounded summary string, or empty when there is no usable
    ///   accepted evidence.
    public static func summary(
        for samples: [PersonalizationSample],
        filterApp: String? = nil,
        bounds: Bounds = .default
    ) -> String {
        var accepted = samples.lazy
            .filter { $0.outcome == .accepted && !$0.completion.isEmpty }
        if let filterApp {
            accepted = accepted.filter { $0.appIdentifier == filterApp }
        }

        var lines: [String] = []
        var count = 0
        for sample in accepted {
            guard count < bounds.maxSamples else { break }
            count += 1
            let prefix = singleLine(String(sample.prefix.suffix(bounds.maxPrefixChars)))
            let completion = singleLine(String(sample.completion.suffix(bounds.maxCompletionChars)))
            guard !prefix.isEmpty, !completion.isEmpty else { continue }
            lines.append("- \(prefix) → \(completion)")
        }

        guard !lines.isEmpty else { return "" }
        var summary = "Examples from your accepted completions:\n" + lines.joined(separator: "\n")
        if summary.count > bounds.maxTotalChars {
            summary = String(summary.prefix(bounds.maxTotalChars))
        }
        return summary
    }
}
