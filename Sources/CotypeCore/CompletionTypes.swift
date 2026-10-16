import Foundation

/// A single request entering the completion pipeline.
///
/// This is the input contract. Anything that can produce a request (a typing
/// trigger, a hotkey, a menu action) can drive the pipeline.
public struct CompletionRequest {
    /// Bundle identifier of the frontmost app (e.g. "com.apple.dt.Xcode").
    public var appIdentifier: String
    /// Text before the cursor.
    public var prefix: String
    /// Text after the cursor (used for fill-in-the-middle models).
    public var suffix: String
    /// Detected source language, if known.
    public var language: String?
    /// The document being edited, if known.
    public var documentURL: URL?
    /// Free-form extension point: pass anything stage-specific without
    /// changing the request type.
    public var extra: [String: String]

    public init(
        appIdentifier: String = "unknown",
        prefix: String = "",
        suffix: String = "",
        language: String? = nil,
        documentURL: URL? = nil,
        extra: [String: String] = [:]
    ) {
        self.appIdentifier = appIdentifier
        self.prefix = prefix
        self.suffix = suffix
        self.language = language
        self.documentURL = documentURL
        self.extra = extra
    }
}

/// Context gathered around the cursor, ready for prompt building.
public struct CompletionContext {
    public var prefix: String
    public var suffix: String
    public var language: String?
    public var appIdentifier: String
    public var documentURL: URL?
    public var extra: [String: String]

    public init(
        prefix: String,
        suffix: String = "",
        language: String? = nil,
        appIdentifier: String = "unknown",
        documentURL: URL? = nil,
        extra: [String: String] = [:]
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.language = language
        self.appIdentifier = appIdentifier
        self.documentURL = documentURL
        self.extra = extra
    }
}

/// A prompt ready to hand to an inference engine.
public struct Prompt {
    /// System / instruction channel.
    public var system: String
    /// User / content channel.
    public var user: String
    /// Optional fill-in-the-middle suffix for models that support FIM.
    public var suffix: String?

    /// Plain-text continuation form. When set, an engine that can do raw text
    /// completion sends exactly this document (no chat template) and the model
    /// simply keeps writing it. `system`/`user` stay filled as the chat fallback.
    public var continuation: ContinuationPrompt?

    public init(system: String = "", user: String, suffix: String? = nil, continuation: ContinuationPrompt? = nil) {
        self.system = system
        self.user = user
        self.suffix = suffix
        self.continuation = continuation
    }

    /// User content including text after the cursor when doing contextual
    /// infill. Chat models do not expose a universal FIM transport, so both
    /// built-in engines send the suffix as clearly delimited context.
    public var userWithSuffixContext: String {
        guard let suffix, !suffix.isEmpty else { return user }
        // Background before the scaffold, so the prompt still ends on
        // "Output:" where the continuation belongs.
        return """
        <after_cursor>
        \(suffix)
        </after_cursor>

        \(user)
        """
    }
}

/// A document for plain-text continuation ("keep writing this").
///
/// An instruction-tuned model asked to *answer* with a continuation replies to
/// the text, restates it, or drifts (the 2026-08 gate: 37.9-58.6% valid). Asked
/// to *continue* the raw text it behaves like a base model and writes the next
/// words. Two details make that work:
///
/// - Token healing. A prompt that ends in a space ends on a lone space token,
///   which the model almost never saw in training, so it derails. The single
///   trailing space is moved out of `text` into `requiredLeading`; the engine
///   forces the first generated token to start with it and strips it again, so
///   callers still receive a continuation relative to the real prefix.
/// - One line. Generation stops at the first line break: a suggestion finishes
///   the current line, never starts a new paragraph.
public struct ContinuationPrompt: Equatable, Sendable {
    /// The document the model continues: optional context block + prefix.
    public var text: String
    /// Whitespace removed from the end of `text` that the output must begin with.
    public var requiredLeading: String

    public init(text: String, requiredLeading: String = "") {
        self.text = text
        self.requiredLeading = requiredLeading
    }

    /// Stop sequences for continuation: the suggestion ends at the line end.
    public static let stopSequences = ["\n"]

    /// Split one trailing space off `prefix` for token healing. Two or more
    /// trailing spaces, tabs, and line breaks stay in the text (they are real
    /// layout, and a lone "\n" token is common in training data).
    public static func healed(_ prefix: String) -> (body: String, requiredLeading: String) {
        guard prefix.hasSuffix(" "), !prefix.hasSuffix("  ") else { return (prefix, "") }
        return (String(prefix.dropLast()), " ")
    }

    /// Remove `requiredLeading` from the start of streamed output, across token
    /// boundaries. Feed each piece; returns what may be emitted now.
    public struct LeadingStripper: Sendable {
        private var remaining: Substring
        public init(_ required: String) { remaining = Substring(required) }

        public mutating func strip(_ piece: String) -> String {
            guard !remaining.isEmpty else { return piece }
            var text = Substring(piece)
            while let first = remaining.first, let head = text.first, first == head {
                remaining.removeFirst()
                text.removeFirst()
            }
            // The model did not reproduce the required boundary (only possible
            // when the engine could not constrain the first token): stop waiting
            // for it and pass the text through; the caret-boundary rules and the
            // sanitizer handle it from there.
            if !text.isEmpty { remaining = "" }
            return String(text)
        }
    }
}

/// A token streamed back from an inference engine.
public enum CompletionEvent: Equatable {
    case token(String)
    case end
}

/// The outcome of a completed generation, after canonical sanitization.
///
/// `suggestion(text)` carries a usable continuation. `noSuggestion` is an
/// explicit abstain — the model produced nothing valid (end-of-generation before
/// content, pure prompt echo, or only forbidden control text) — and is scored
/// separately from a generation failure, which throws an `Error` through the
/// pipeline instead.
public enum CompletionOutcome: Equatable {
    case suggestion(String)
    case noSuggestion
}

/// Timing and volume captured during one pipeline run.
public struct PipelineTimings: Equatable {
    /// Wall-clock distance from the request to the first streamed token.
    public var timeToFirstToken: TimeInterval
    /// Number of generated (post-engine) tokens emitted to the renderer.
    public var tokenCount: Int
    /// Total generation wall-clock time.
    public var generationTime: TimeInterval
    /// True when the pipeline ended the stream itself because more text could
    /// no longer change the candidate.
    public var stoppedEarly: Bool

    public init(
        timeToFirstToken: TimeInterval = 0,
        tokenCount: Int = 0,
        generationTime: TimeInterval = 0,
        stoppedEarly: Bool = false
    ) {
        self.timeToFirstToken = timeToFirstToken
        self.tokenCount = tokenCount
        self.generationTime = generationTime
        self.stoppedEarly = stoppedEarly
    }

    /// Generated tokens per second over the decode window. A tiny generation
    /// window (immediate end-of-generation) makes the rate meaningless, so it is
    /// reported as zero rather than an inflated figure.
    public var tokensPerSecond: Double {
        generationTime > 0.002 ? Double(tokenCount) / generationTime : 0
    }
}

/// Pipeline phases, used to tag observability events.
public enum CompletionPhase: String, CaseIterable, Sendable {
    case trigger
    case context
    case prompt
    case inference
    case render
    case insert
}

/// One observability event emitted at a pipeline boundary.
///
/// Subscribe to `CompletionPipeline.events` to see exactly what each stage
/// produced — the seam that makes the whole loop inspectable and debuggable.
public struct PipelineEvent {
    public let phase: CompletionPhase
    public let summary: String
    public let payload: Any?
    public let date: Date

    public init(phase: CompletionPhase, summary: String, payload: Any? = nil, date: Date = Date()) {
        self.phase = phase
        self.summary = summary
        self.payload = payload
        self.date = date
    }
}
