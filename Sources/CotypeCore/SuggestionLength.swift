import Foundation

/// How long a suggestion may be. One setting drives the prompt wording, the
/// word cap on the output, and the token budget, so they never disagree.
/// Mirrors TabType's short/medium/long presets (3 / 8 / 14 words).
public enum SuggestionLength: String, CaseIterable, Codable, Sendable {
    case short
    case medium
    case long

    public static let defaultsKey = "suggestionLength"
    public static let `default`: SuggestionLength = .medium

    public static func current(_ defaults: UserDefaults = .standard) -> SuggestionLength {
        defaults.string(forKey: defaultsKey).flatMap(SuggestionLength.init(rawValue:)) ?? .default
    }

    public var title: String {
        switch self {
        case .short: return "1-3 words"
        case .medium: return "3-6 words"
        case .long: return "Full sentence"
        }
    }

    /// Replaces "(usually 2-5 words)" in the system prompt.
    public var promptPhrase: String {
        switch self {
        case .short: return "(usually 1-3 words)"
        case .medium: return "(usually 3-6 words)"
        case .long: return "(finish the current sentence, up to about 15 words)"
        }
    }

    public var maxWords: Int {
        switch self {
        case .short: return 3
        case .medium: return 6
        case .long: return 16
        }
    }

    public var maxTokens: Int {
        switch self {
        case .short: return 16
        case .medium: return 24
        case .long: return 48
        }
    }

    /// Apply the length wording to a system prompt that uses the default phrase.
    public func applied(to system: String) -> String {
        system.replacingOccurrences(of: "(usually 2-5 words)", with: promptPhrase)
    }
}
