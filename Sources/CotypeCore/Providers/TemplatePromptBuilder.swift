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

    /// The chat lane's system message: a strict continuation directive.
    ///
    /// Measured on 2026-10-17 against the old `Input:/Output:` few-shot system:
    /// on code and prose prefixes this produced real continuations instead of
    /// answers or echoed text (5/12 exact vs 3/12), and it obeyed a style note
    /// appended as plain prose. The chat template separates the system role
    /// (`/props` reports `supports_system_role = true`), so this is the supported
    /// place for the author's instructions.
    public static let chatSystem = """
    You are an inline autocomplete engine. Continue the user's message with the next few words the author would type. Output ONLY the continuation: no quotes, no explanation, no markdown, no repetition of their text, and never answer or comment on it.
    """

    /// Compose the chat system message with the shared length directive and the
    /// author's own style note. The continuation directive stays first so a
    /// style request cannot turn the model into an answering assistant.
    public static func chatSystem(length: SuggestionLength, customStyle: String) -> String {
        var message = chatSystem + " " + length.chatDirective
        let note = customStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            message += "\n\nWriting style: " + note
        }
        return message
    }

    /// The one composition both the app and the eval use: the continuation
    /// lane's system is unused boilerplate; the instruction lane gets the
    /// continuation directive plus the author's style note.
    public static func system(
        for style: PromptStyle,
        customInstruction: String,
        length: SuggestionLength = .default
    ) -> String {
        switch style {
        case .continuation: return defaultSystem
        case .instruction: return chatSystem(length: length, customStyle: customInstruction)
        }
    }

    /// The user turn: the text before the caret, in the examples' scaffold.
    /// Used by the continuation/chat fallback only; the instruction lane sends
    /// the raw prefix so the model is not asked to fill a template.
    public static let defaultUser = "Input: {{prefix}}\nOutput:"

    /// Upper bounds on what a continuation document carries, so a long field
    /// or a busy window cannot crowd out the text nearest the caret.
    public static let continuationPrefixChars = 2000
    public static let continuationContextChars = 1200
    /// The author's facts get their own bounded slice of the context budget, so
    /// a long window context can never evict them.
    public static let continuationFactsChars = 600

    /// The task the model is given when nothing on screen frames the text.
    public static let continuationTask = "Write a short, ordinary message to a colleague."
    /// The task when visible text is on screen; that text follows on a new line.
    public static let continuationReplyTask = "Write a short, ordinary reply to this:"
    public static let continuationFactsHeading = "My details:"

    /// The prompt an engine continues: one task turn, then the model's turn
    /// already begun with the author's text, so the model keeps writing it.
    ///
    /// Measured on 2026-11-03 on 66 synthetic prose cases with gemma-4-E2B-it. The
    /// bare document made this instruction-tuned model answer as a chatbot ("I am
    /// Gemma 4", "[Your Name]"). Asking it to "continue my text" made it reply to
    /// that request ("I'm ready. Type away."), so the task names the kind of text,
    /// not the act of typing. A `<context>` block read as a task too ("thanks for
    /// the context").
    ///
    /// The author's facts are sent only when the text calls for them: present on
    /// every request, they pulled the author's name into 17 of 38 unrelated
    /// sentences. See `AuthorFacts.areCalledFor`.
    ///
    /// Code goes as the bare document: the same run scored 22 of 29 valid on the
    /// seeded set that way and 20 of 29 under the message task.
    ///
    /// The context is budgeted per part, in priority order: the author's facts
    /// first, then visible window text, within `continuationContextChars`.
    public static func continuation(
        prefix: String,
        facts: String = "",
        windowContext: String = ""
    ) -> ContinuationPrompt {
        let factText = facts
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(40)
            .joined(separator: "\n")
        let factBlock = AuthorFacts.areCalledFor(afterText: prefix)
            ? String(factText.prefix(continuationFactsChars))
            : ""

        let used = factBlock.count + (factBlock.isEmpty ? 0 : 1)
        let windowLimit = max(0, continuationContextChars - used)
        // Keep the tail of the window text: the text nearest the caret/most
        // recent is at the end of the collected block.
        let windowBlock = String(
            windowContext
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .suffix(windowLimit)
        )

        var task = windowBlock.isEmpty ? continuationTask : continuationReplyTask + "\n" + windowBlock
        if !factBlock.isEmpty {
            task += "\n\n" + continuationFactsHeading + "\n" + factBlock
        }
        let bounded = String(prefix.suffix(continuationPrefixChars))
        let (body, leading) = ContinuationPrompt.healed(neutralizingControlMarkers(bounded))
        if TextKind.looksLikeCode(prefix) {
            return ContinuationPrompt(text: body, requiredLeading: leading)
        }
        let turns = "<|turn>user\n\(neutralizingControlMarkers(task))<turn|>\n<|turn>model\n"
        return ContinuationPrompt(text: turns + body, requiredLeading: leading)
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

/// Tells code from prose by the shape of the text nearest the caret.
public enum TextKind {
    private static let codeShape = #"(?m)[{};]|=|->|\w\(|^(\t| {4})|^\s*(func|def|class|struct|import|package|const|let|var|fn|public|private|#|```)(\s|$)|</?\w+>"#

    public static func looksLikeCode(_ text: String) -> Bool {
        String(text.suffix(200)).range(of: codeShape, options: .regularExpression) != nil
    }

    /// At least four letters' worth of text before the caret. A CJK character
    /// carries about two letters' worth.
    public static func hasEnoughToContinue(_ text: String) -> Bool {
        var weight = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            weight += scalar.properties.isIdeographic ? 2 : 1
            if weight >= 4 { return true }
        }
        return false
    }
}

/// Removes what an instruction-tuned model adds when it talks instead of writing.
enum ModelTalk {
    /// A fill-in slot, whole or still streaming: "[Your Name]", "[Option A]",
    /// "[Topic]". Code like `[Int]` or `[String: Any]` does not match, and a
    /// Markdown link is left alone.
    private static let placeholder = #"\[[A-Z][A-Za-z'/]*( [A-Za-z'/]+)+\](?!\()|\[(Topic|Name|Date|Time|Company|Link)\](?!\()|\[[A-Z][A-Za-z'/]* [A-Za-z'/ ]*$"#
    private static let offerOfOptions = #"(?i)(here are|a few) (a few |some )?options|depending on the context"#

    static func removed(from text: String) -> String {
        guard text.contains("[") || text.range(of: offerOfOptions, options: .regularExpression) != nil else { return text }
        if text.range(of: offerOfOptions, options: .regularExpression) != nil { return "" }
        guard let slot = text.range(of: placeholder, options: .regularExpression) else { return text }
        let before = text[..<slot.lowerBound]
        return String(before.reversed().drop(while: \.isWhitespace).reversed())
    }
}

/// Decides when the author's own facts belong in a prompt.
public enum AuthorFacts {
    /// Text that ends where a name, address, employer or place comes next.
    private static let callsForFacts = #"(?i)(my name is|this is|e-?mail( address)?( is)?( at)?|reach me( at)?|contact me( at)?|i work (at|for)|i'?m with|i am with|based in|i'?m the\b.*|i am the\b.*|my (role|title|company)( is)?|regards,?|sincerely,?|best,?|cheers,?|yours,?|我叫|我是|邮箱(是)?|我在)\s*$"#

    public static func areCalledFor(afterText text: String) -> Bool {
        String(text.suffix(60)).range(of: callsForFacts, options: .regularExpression) != nil
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
        userTemplate: String? = nil,
        style: PromptStyle = .default,
        personalFacts: String = ""
    ) {
        self.systemTemplate = systemTemplate
        self.userTemplate = userTemplate
            ?? (style == .instruction ? "{{prefix}}" : AutocompletePrompt.defaultUser)
        self.style = style
        self.personalFacts = personalFacts
    }

    public func buildPrompt(context: CompletionContext) async throws -> Prompt {
        let user: String
        if style == .continuation,
           userTemplate == AutocompletePrompt.defaultUser || userTemplate == "{{prefix}}",
           let windowContext = context.extra["windowContext"],
           !windowContext.isEmpty {
            user = Self.contextualUserText(prefix: context.prefix, windowContext: windowContext)
        } else {
            user = render(userTemplate, context: context)
        }
        var system = render(systemTemplate, context: context)
        // Learned examples belong to the system channel. The continuation lane
        // never transmits `system` (it sends `continuation` only), so this cannot
        // leak into a plain-text prompt; the instruction lane does send it.
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
