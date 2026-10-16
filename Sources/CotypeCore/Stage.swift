import Foundation

/// Each stage of the completion loop is a protocol. Swap in your own
/// implementation, or wrap an existing one, without touching the rest.
/// This is the extensibility surface that Cotypist does not expose.

/// Detects *when* a completion should be offered (typing pause, trigger key).
public protocol TriggerProvider {
    /// Async stream of trigger moments. Each element is a best-effort request.
    func triggers() -> AsyncStream<CompletionRequest>
}

/// Collects context around the cursor: focused-editor text, clipboard,
/// screenshot, document metadata, and anything else.
public protocol ContextProvider {
    func provideContext(for request: CompletionRequest) async throws -> CompletionContext
}

/// Turns gathered context into a model-ready prompt.
public protocol PromptBuilder {
    func buildPrompt(context: CompletionContext) async throws -> Prompt
}

/// Runs a model and streams completion tokens. Implementations may be local
/// (llama.cpp) or remote (OpenAI, Anthropic, a local server) — the pipeline
/// does not care which.
public protocol InferenceEngine {
    /// Human-readable name, surfaced in logs/events.
    var name: String { get }
    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error>
}

/// Displays the in-progress and final completion (ghost text, overlay, inline).
public protocol CompletionRenderer {
    func present(_ candidate: String, for request: CompletionRequest)
    func clear()
}

/// Commits accepted text into the focused editor (pasteboard swap, AX insert,
/// or any other strategy).
///
/// All three methods are protocol requirements so the most target-aware
/// `insert(_:appIdentifier:focusTarget:)` is *dynamically* dispatched: an
/// inserter that re-verifies the insertion target (the focus guard) is always
/// called, rather than being bypassed by a static protocol-extension default.
public protocol CompletionInserter {
    /// Insert text into the focused editor with no target verification.
    func insert(_ text: String) async throws
    /// Insert text, re-verifying the target app before pasting. Implementations
    /// that do not need a focus guard default to the plain `insert(_:)`.
    func insert(_ text: String, appIdentifier: String?) async throws
    /// Insert text, re-verifying the full focused-field identity before
    /// committing. Implementations that do not need the field-level guard
    /// default to delegating to the app-identifier form.
    func insert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws
}

public extension CompletionInserter {
    /// Default target-aware behavior: no verification, delegate to `insert(_:)`.
    func insert(_ text: String, appIdentifier: String?) async throws {
        try await insert(text)
    }
    /// Default field-aware behavior: no field-level verification, delegate to
    /// the app-identifier form.
    func insert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws {
        try await insert(text, appIdentifier: appIdentifier)
    }
}
