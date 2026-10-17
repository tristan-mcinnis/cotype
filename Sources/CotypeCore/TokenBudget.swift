import Foundation

/// The one policy that decides how many tokens a completion request may use.
///
/// Every surface reads this: the Settings pane displays it, the daemon lane and
/// the in-process lane put the same number in `max_tokens`, and diagnostics
/// reports it. A stored `maxTokens` value is honoured only when the user chose
/// the explicit mode; an old value left behind by a previous build therefore
/// cannot silently disagree with the suggestion-length setting.
public struct TokenBudget {
    /// `auto` (default) or `explicit`. Absent/unknown reads as `auto`.
    public static let modeKey = "maxTokensMode"
    /// The explicit override, read only when `modeKey == explicit`.
    public static let explicitValueKey = "maxTokens"

    /// The server lanes clamp to `OpenAICompatibleEngine.maxAllowedTokens`.
    public static let maximum = OpenAICompatibleEngine.maxAllowedTokens
    /// A budget below this cannot finish a short phrase.
    public static let minimum = 16
    /// What the explicit control starts at when first enabled.
    public static let explicitDefault = 64

    public enum Mode: String, CaseIterable, Sendable {
        case auto
        case explicit
    }

    public enum Source: Equatable, Sendable {
        case automatic(SuggestionLength)
        case explicitOverride
    }

    public let tokens: Int
    public let source: Source

    public init(tokens: Int, source: Source) {
        self.tokens = Self.clamped(tokens)
        self.source = source
    }

    /// Clamp any requested budget into `minimum...maximum`.
    public static func clamped(_ tokens: Int) -> Int {
        min(max(tokens, minimum), maximum)
    }

    public static func mode(_ defaults: UserDefaults = .standard) -> Mode {
        defaults.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .auto
    }

    /// The effective budget for the current preferences.
    ///
    /// `auto` follows `SuggestionLength` (16 / 24 / 48 tokens), which is also the
    /// word cap shown in Settings, so the two can never disagree. An explicit
    /// override is clamped like every other request.
    public static func effective(_ defaults: UserDefaults = .standard) -> TokenBudget {
        switch mode(defaults) {
        case .auto:
            let length = SuggestionLength.current(defaults)
            return TokenBudget(tokens: length.maxTokens, source: .automatic(length))
        case .explicit:
            let stored = defaults.object(forKey: explicitValueKey) as? Int ?? explicitDefault
            return TokenBudget(tokens: stored, source: .explicitOverride)
        }
    }

    /// A short, truthful label for Settings and diagnostics.
    public var summary: String {
        switch source {
        case .automatic(let length):
            return "Auto · \(length.title) · \(tokens) tokens"
        case .explicitOverride:
            return "Custom · \(tokens) tokens"
        }
    }
}
