import Foundation

/// Emoji in suggestions. Off by default: a suggestion ends before its first
/// emoji, so the model's habit of closing a chat line with one never reaches
/// the ghost text.
public enum EmojiFilter {
    public static let defaultsKey = "allowEmoji"

    public static func allowsEmoji(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// The text before its first emoji, less the space that led up to it.
    static func cutAtFirstEmoji(_ text: String) -> String {
        guard let index = text.firstIndex(where: isEmoji) else { return text }
        return String(text[..<index].reversed().drop(while: \.isWhitespace).reversed())
    }

    /// Digits, "#", "*", "©" and "™" carry the emoji property too, so a lone
    /// scalar counts only when it draws as emoji by default or sits in the
    /// symbol blocks that do ("❤", "☺", "✔").
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        if first.properties.isEmojiPresentation { return true }
        if scalars.count > 1 {
            return scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 || $0.value == 0x200D }
        }
        return (0x2600...0x27BF).contains(first.value)
    }
}
