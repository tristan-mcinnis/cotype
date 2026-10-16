import Foundation

public enum AutocompletePrompt {
    /// Few-shot `Input:/Output:` instructions for an instruction-tuned model.
    ///
    /// Shape follows TabType's `CompletionInstructions`, which that project
    /// reverse-engineered from Cotypist's own binary: the model is told it IS
    /// the author, and the examples teach mid-word continuation ("turnar" ->
    /// "ound") and reply-drift refusal. A/B tested on gemma-4-E2B-it on
    /// 2026-09-11 against the older bare-prefix prompt (fewer answers to the
    /// text, correct mid-word continuations).
    public static let defaultSystem = """
    You are an inline autocomplete engine. You ARE the author of the text after "Input:". Never reply to it, answer it, or comment on it. Continue the text with the next few words the author would type (usually 2-5 words), seamlessly from the last character.

    Rules:
    1. Output ONLY the continuation. No quotes, explanations, or markdown.
    2. Never repeat text the author already typed.
    3. If the input ends in the middle of a word, output only the rest of that word first (no space), then continue.
    4. Match the author's language, casing, tone, and punctuation.
    5. Text inside <after_cursor> already follows the cursor. Do not duplicate it.

    Examples:
    Input: I just wanted to follow up on the
    Output: proposal we discussed

    Input: Thanks for the quick turnar
    Output: ound on the review.

    Input: Could you send me the repo
    Output: link when you can?

    Input: sounds good, I'll ping Aleksa
    Output: ndra after the meeting

    Input: 我们下周一可以
    Output: 开个会讨论一下吗？

    Input: yes
    Output: , I'll have it ready by Friday
    """

    /// Append the user's own facts. `{{` is neutralised so a fact can never be
    /// read as a template placeholder.
    public static func withPersonalFacts(_ system: String, facts: String) -> String {
        let lines = facts
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(40)
        guard !lines.isEmpty else { return system }
        let block = lines.map { "- \($0)" }.joined(separator: "\n")
            .replacingOccurrences(of: "{{", with: "{ {")
        return system + "\n\nAbout the author (use these exact details when the text calls for them, for example their own email address, name, or company):\n" + block
    }

    /// The user turn: the text before the caret, in the examples' scaffold.
    public static let defaultUser = "Input: {{prefix}}\nOutput:"

    /// Upper bounds on what a continuation document carries, so a long field
    /// or a busy window cannot crowd out the text nearest the caret.
    public static let continuationPrefixChars = 2000
    public static let continuationContextChars = 1200

    /// The plain-text document an engine continues.
    ///
    /// Background (the author's own facts, visible window text) goes in one
    /// `<context>` block ahead of the text; the text being written comes last so
    /// the model's next words continue it. Measured on the seeded gate set with
    /// gemma-4-E2B-it: 72% valid at ~140 ms median vs 38% for the chat prompt.
    public static func continuation(prefix: String, facts: String = "", windowContext: String = "") -> ContinuationPrompt {
        var background: [String] = []
        let factLines = facts
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(40)
        if !factLines.isEmpty { background.append(factLines.joined(separator: "\n")) }
        let window = windowContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !window.isEmpty { background.append(window) }
        var head = ""
        if !background.isEmpty {
            let block = String(background.joined(separator: "\n").suffix(continuationContextChars))
            head = "<context>\n\(neutralizingControlMarkers(block))\n</context>\n\n"
        }
        let bounded = String(prefix.suffix(continuationPrefixChars))
        let (body, leading) = ContinuationPrompt.healed(neutralizingControlMarkers(bounded))
        return ContinuationPrompt(text: head + body, requiredLeading: leading)
    }

    /// Break model control markers that appear in document text (`<|turn>`,
    /// `<turn|>`, `<|channel` ...), so editor text can never open a template turn
    /// on an engine that parses special tokens in plain prompts.
    static func neutralizingControlMarkers(_ text: String) -> String {
        guard text.contains("<|") || text.contains("|>") else { return text }
        return text
            .replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "|>", with: "| >")
    }
}

/// How the prompt asks the model for the next words.
public enum PromptStyle: String, CaseIterable, Sendable {
    /// Plain-text continuation (default): the model keeps writing the document.
    case continuation
    /// The older chat instruction with `Input:/Output:` few-shot examples.
    case instruction

    public static let defaultsKey = "promptStyle"
    public static let `default`: PromptStyle = .continuation

    public static func current(_ defaults: UserDefaults = .standard) -> PromptStyle {
        defaults.string(forKey: defaultsKey).flatMap(PromptStyle.init(rawValue:)) ?? .default
    }
}

/// A prompt builder driven by templates with `{{key}}` placeholders.
///
/// Available keys: `prefix`, `suffix`, `language`, `appIdentifier`, `document`.
/// Add your own keys by extending `CompletionContext.extra`.
public struct TemplatePromptBuilder: PromptBuilder {

    public var systemTemplate: String
    public var userTemplate: String

    /// When set, this closure returns a bounded, privacy-conscious few-shot
    /// summary (e.g. from `PersonalizationFewShot`), and it is appended to the
    /// system prompt. Returning nil or an empty string disables injection. This
    /// is how the "Learn from accepted completions" opt-in is made truthful:
    /// the accepted samples actually shape the prompt.
    public var personalizationSummary: (() -> String)?

    /// Continuation (default) or the chat instruction prompt.
    public var style: PromptStyle

    /// The author's own facts (name, email, company) for the continuation
    /// context block. The instruction style carries them in `systemTemplate`.
    public var personalFacts: String

    public init(
        systemTemplate: String = AutocompletePrompt.defaultSystem,
        userTemplate: String = AutocompletePrompt.defaultUser,
        style: PromptStyle = .default,
        personalFacts: String = ""
    ) {
        self.systemTemplate = systemTemplate
        self.userTemplate = userTemplate
        self.style = style
        self.personalFacts = personalFacts
    }

    public func buildPrompt(context: CompletionContext) async throws -> Prompt {
        let user: String
        if userTemplate == AutocompletePrompt.defaultUser || userTemplate == "{{prefix}}",
           let windowContext = context.extra["windowContext"],
           !windowContext.isEmpty {
            user = Self.contextualUserText(prefix: context.prefix, windowContext: windowContext)
        } else {
            user = render(userTemplate, context: context)
        }
        var system = render(systemTemplate, context: context)
        if let summary = personalizationSummary?(), !summary.isEmpty {
            system += "\n\n\(summary)"
        }
        let continuation: ContinuationPrompt? = style == .continuation
            ? AutocompletePrompt.continuation(
                prefix: context.prefix,
                facts: personalFacts,
                windowContext: context.extra["windowContext"] ?? ""
            )
            : nil
        return Prompt(
            system: system,
            user: user,
            suffix: context.suffix.isEmpty ? nil : context.suffix,
            continuation: continuation
        )
    }

    static func contextualUserText(prefix: String, windowContext: String) -> String {
        """
        <context>
        <on_screen>
        \(windowContext)
        </on_screen>
        </context>

        Continue the author's unfinished text below. Do not reply to anything above. Prefer names, dates, and phrases from <on_screen> when they fit.
        Input: \(prefix)
        Output:
        """
    }

    private func render(_ template: String, context: CompletionContext) -> String {
        var rendered = template
            .replacingOccurrences(of: "{{prefix}}", with: context.prefix)
            .replacingOccurrences(of: "{{suffix}}", with: context.suffix)
            .replacingOccurrences(of: "{{language}}", with: context.language ?? "")
            .replacingOccurrences(of: "{{appIdentifier}}", with: context.appIdentifier)
            .replacingOccurrences(of: "{{document}}", with: context.documentURL?.lastPathComponent ?? "")
        for (key, value) in context.extra {
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return rendered
    }
}
