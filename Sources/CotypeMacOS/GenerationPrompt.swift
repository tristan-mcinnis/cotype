import CotypeCore

/// Builds the prompt for one generation from settings the controller has
/// already read, so the precedence rules stay testable without a controller.
enum GenerationPrompt {
    static func make(
        length: SuggestionLength,
        style: PromptStyle,
        storedPrompt: String?,
        websitePrompt: String?,
        appPrompt: String?,
        personalFacts: String
    ) -> TemplatePromptBuilder {
        // A prompt only counts when the user actually wrote something. The
        // shipped default is instruction boilerplate for the chat lane and is
        // never treated as a custom instruction.
        let globalInstruction = storedPrompt == AutocompletePrompt.defaultSystem ? nil : storedPrompt
        // One precedence for both prompt styles: website, then app, then global.
        // The chosen style never changes because an override exists.
        let customInstruction = firstNonEmpty([websitePrompt, appPrompt, globalInstruction])
        // The chat lane's system message is the continuation directive plus the
        // author's style note. The continuation lane does not transmit `system`.
        let system = AutocompletePrompt.system(for: style, customInstruction: customInstruction, length: length)
        return TemplatePromptBuilder(
            systemTemplate: AutocompletePrompt.withPersonalFacts(length.applied(to: system), facts: personalFacts),
            style: style,
            personalFacts: personalFacts
        )
    }

    /// The first non-empty, trimmed value, so an empty override never shadows
    /// a parent value in the site > app > global chain.
    static func firstNonEmpty(_ candidates: [String?]) -> String {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            return trimmed
        }
        return ""
    }
}
