import Foundation

/// Pure state machine for the Cotypist-style typing interaction loop.
///
/// This is the approved public seam. It is **pure**: it holds no AppKit/AX
/// objects, runs no timers, and makes no I/O. It only decides, for a stream of
/// user/engine events, what the host driver must *do* (the `Effect`s it
/// returns), and tracks the visible interaction state (`state`, `ghost`).
///
/// The host (`CompletionController` + `GlobalKeyMonitor`) owns the real work:
/// running the pause timer, driving the pipeline, rendering the ghost overlay,
/// and inserting accepted text. This type just decides the *intent*.
///
/// The loop it models is **manual-first**: a completion starts only from an
/// explicit force-trigger (`manualTrigger`). Typing, navigation, document edits,
/// and pointer-originated context changes never start a generation on their own.
///
/// 1. `idle`: ordinary typing/editing/pointer movement leaves the loop idle. A
///    `manualTrigger` → `generating`.
/// 2. While `generating`, a user edit (typed/edited/context-moved) promptly
///    cancels the in-flight generation and returns to `idle` — it never
///    re-bounces into an automatic regeneration.
/// 3. A candidate arrives (`generated`) → `awaitingAccept`, with the candidate
///    stored as `ghost`. The user can:
///      - press Tab → accept the **next word** only (stepping keeps the rest);
///      - press the full-suggestion chord → accept the **whole** ghost;
///      - press Escape → dismiss and enter a short `cooldown`;
///      - type or edit → the stale ghost is dismissed and the loop goes idle.
/// 4. `manualTrigger` works in every state, including during `cooldown`, and
///    supersedes any in-flight generation.
///
/// An explicit opt-in seam (`autoSuggestEnabled`, default `false`) restores the
/// future automatic lane: typing pauses → `debouncing` → `debounceElapsed` →
/// `beginGeneration(.debounce)`, with type-through regeneration on a fully typed
/// ghost. Even in that lane a `.contextMoved` pointer/navigation event never arms
/// the debounce.
///
/// Safety: the machine never consumes typing itself; it only *observes* observed
/// input to drive dismiss/cancel/type-through. The driver is responsible for
/// never consuming Command chords and for preserving the sensitive-context and
/// disabled-app gating when it actually begins a generation.
public struct CompletionInteraction: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case idle
        /// Waiting for the pause timer to elapse before auto-triggering.
        case debouncing
        /// A generation is in flight.
        case generating
        /// A candidate is displayed and waiting for accept/dismiss/type-through.
        case awaitingAccept
        /// Escape-dismissed: auto-trigger is suppressed briefly.
        case cooldown
    }

    /// Why a generation was requested.
    public enum Source: Equatable, Sendable {
        /// Auto-trigger after a typing pause.
        case debounce
        /// Explicit force-trigger (chord, menu, repeat).
        case manual
    }

    /// Input events the driver feeds the machine.
    public enum Event: Equatable, Sendable {
        /// Ordinary characters inserted at the caret (not a shortcut chord).
        case typed(String)
        /// A keyboard-originated non-character document mutation (backspace,
        /// delete, return, paste, cut, undo, redo, Tab with no candidate). Always
        /// invalidates any stale ghost/generation.
        case edited
        /// A pointer/navigation-originated context change (a mouse-down moved the
        /// caret or focus, or the window/element changed). Never arms the
        /// debounce, even in the opt-in auto lane: a click is not typing.
        case contextMoved
        /// The pause timer fired: time to auto-trigger.
        case debounceElapsed
        /// The Escape cooldown timer fired.
        case cooldownElapsed
        /// Explicit force-trigger.
        case manualTrigger
        /// Partial candidate streamed during generation (drives live ghost).
        case streamed(String)
        /// A candidate completed generation.
        case generated(String)
        /// Generation produced no candidate (or was blocked by the driver).
        case noSuggestion
        /// Tab: accept the next word.
        case acceptNextWord
        /// Full-suggestion chord: accept the whole candidate.
        case acceptAll
        /// Escape: dismiss the candidate and pause.
        case dismissed
    }

    /// The commands the driver must perform in response to an event.
    public enum Effect: Equatable, Sendable {
        case none
        /// (Re)start the pause timer.
        case startDebounce
        /// Start the Escape cooldown timer.
        case startCooldown
        /// Begin a generation now.
        case beginGeneration(Source)
        /// Cancel/supersede the in-flight generation.
        case cancelGeneration
        /// Insert `String` into the editor (an accepted segment).
        case commit(String)
    }

    public private(set) var state: State = .idle
    /// The visible continuation text after the caret. Leading characters are
    /// consumed as the user types through a match; empty when nothing is shown.
    public private(set) var ghost: String = ""

    /// True after at least one edit/type while in `.cooldown`. When the cooldown
    /// expires we debounce once (rather than going cleanly idle) if edits happened.
    private var didEditDuringCooldown = false

    /// Opt-in seam for automatic (pause-triggered) suggestions.
    ///
    /// Default `false`: the loop is manual-first. Typing, navigation, editing,
    /// and pointer-originated context changes never arm the debounce timer or
    /// start a generation on their own — only an explicit `.manualTrigger` does.
    /// There is no UI for this in the manual v1 slice; the future automatic lane
    /// flips it on deliberately.
    public var autoSuggestEnabled: Bool

    public init(autoSuggestEnabled: Bool = false) {
        self.autoSuggestEnabled = autoSuggestEnabled
    }

    public var isAwaitingAccept: Bool { state == .awaitingAccept }
    public var isGenerating: Bool { state == .generating }
    public var isDebouncing: Bool { state == .debouncing }
    public var isCoolingDown: Bool { state == .cooldown }

    /// Handle one event, returning the effects the driver must perform.
    /// The call updates `state`/`ghost` first, then effects are emitted.
    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .typed(let text): return handleTyped(text)
        case .edited: return handleEdited()
        case .contextMoved: return handleContextMoved()
        case .debounceElapsed: return handleDebounceElapsed()
        case .cooldownElapsed: return handleCooldownElapsed()
        case .manualTrigger: return handleManualTrigger()
        case .streamed(let text): return handleStreamed(text)
        case .generated(let text): return handleGenerated(text)
        case .noSuggestion: return handleNoSuggestion()
        case .acceptNextWord: return handleAcceptNextWord()
        case .acceptAll: return handleAcceptAll()
        case .dismissed: return handleDismissed()
        }
    }

    // MARK: - Event handlers

    private mutating func handleTyped(_ text: String) -> [Effect] {
        switch state {
        case .idle:
            // Manual-first: ordinary typing never arms the debounce on its own.
            ghost = ""
            guard autoSuggestEnabled else { return [.none] }
            state = .debouncing
            return [.startDebounce]

        case .cooldown:
            // Edits continue while the cooldown suppresses auto-trigger. Only an
            // auto-lane edit resumes the loop when the window expires.
            didEditDuringCooldown = autoSuggestEnabled
            ghost = ""
            return [.none]

        case .debouncing:
            // Typing continues: restart the pause window.
            return [.startDebounce]

        case .generating:
            // Typing supersedes the in-flight generation. Manual-first returns to
            // idle; the opt-in auto lane re-bounces from the updated prefix.
            ghost = ""
            guard autoSuggestEnabled else {
                state = .idle
                return [.cancelGeneration]
            }
            state = .debouncing
            return [.cancelGeneration, .startDebounce]

        case .awaitingAccept:
            return handleTypedWhileAwaiting(text)
        }
    }

    private mutating func handleTypedWhileAwaiting(_ text: String) -> [Effect] {
        // Manual-first: a keystroke while a candidate is showing dismisses it and
        // returns idle. Nothing regenerates automatically.
        guard autoSuggestEnabled else {
            ghost = ""
            state = .idle
            return [.cancelGeneration]
        }

        var remaining = ghost
        for ch in text {
            if ch == remaining.first {
                remaining.removeFirst()
                // Fully typed through mid-batch: treat any leftover chars as
                // fresh typing and debounce to generate the next suggestion.
                if remaining.isEmpty {
                    state = .debouncing
                    ghost = ""
                    return [.startDebounce]
                }
            } else {
                // Mismatch: dismiss the ghost and regenerate from the new prefix.
                state = .debouncing
                ghost = ""
                return [.cancelGeneration, .startDebounce]
            }
        }
        // Every typed character matched but the ghost is not exhausted yet: keep
        // accepting and let type-through continue; no debounce (user is engaged).
        ghost = remaining
        return [.none]
    }

    private mutating func handleDebounceElapsed() -> [Effect] {
        guard state == .debouncing else { return [.none] }
        state = .generating
        ghost = ""
        return [.beginGeneration(.debounce)]
    }

    private mutating func handleCooldownElapsed() -> [Effect] {
        guard state == .cooldown else { return [.none] }
        if didEditDuringCooldown {
            // The user kept editing while suppressed: resume after a short pause
            // instead of going silently idle, so the loop continues cleanly.
            didEditDuringCooldown = false
            state = .debouncing
            return [.startDebounce]
        }
        state = .idle
        return [.none]
    }

    private mutating func handleEdited() -> [Effect] {
        handleDocumentMutation(rearmAutoTrigger: autoSuggestEnabled)
    }

    private mutating func handleContextMoved() -> [Effect] {
        // A pointer/navigation change never arms the debounce, in any mode.
        handleDocumentMutation(rearmAutoTrigger: false)
    }

    /// Shared document/focus invalidation. `rearmAutoTrigger` is true only for a
    /// keyboard-originated edit while the opt-in auto lane is enabled; every
    /// other invalidation (and every edit in manual-first mode) cancels any
    /// in-flight generation and returns to `idle` without scheduling new work.
    private mutating func handleDocumentMutation(rearmAutoTrigger: Bool) -> [Effect] {
        switch state {
        case .idle:
            ghost = ""
            guard rearmAutoTrigger else { return [.none] }
            state = .debouncing
            return [.startDebounce]

        case .debouncing:
            // A keyboard edit continues the pause window; a pointer change leaves
            // the already-armed auto-trigger alone.
            return rearmAutoTrigger ? [.startDebounce] : [.none]

        case .generating:
            // The document/focus changed under a live generation: supersede it.
            ghost = ""
            guard rearmAutoTrigger else {
                state = .idle
                return [.cancelGeneration]
            }
            state = .debouncing
            return [.cancelGeneration, .startDebounce]

        case .awaitingAccept:
            // A non-character edit invalidates the stale ghost.
            ghost = ""
            guard rearmAutoTrigger else {
                state = .idle
                return [.cancelGeneration]
            }
            state = .debouncing
            return [.cancelGeneration, .startDebounce]

        case .cooldown:
            didEditDuringCooldown = rearmAutoTrigger
            ghost = ""
            return [.none]
        }
    }

    private mutating func handleManualTrigger() -> [Effect] {
        switch state {
        case .generating:
            // Supersede the in-flight generation and force a fresh one.
            state = .generating
            return [.cancelGeneration, .beginGeneration(.manual)]
        case .awaitingAccept:
            // Explicit re-trigger while a suggestion is shown: drop it and
            // regenerate from the current context.
            state = .generating
            ghost = ""
            return [.cancelGeneration, .beginGeneration(.manual)]
        case .idle, .debouncing, .cooldown:
            // Force-trigger always works, even during cooldown (the user asked).
            didEditDuringCooldown = false
            state = .generating
            ghost = ""
            return [.beginGeneration(.manual)]
        }
    }

    private mutating func handleStreamed(_ text: String) -> [Effect] {
        guard state == .generating else { return [.none] }
        ghost = text
        return [.none]
    }

    private mutating func handleGenerated(_ text: String) -> [Effect] {
        guard state == .generating else { return [.none] }
        ghost = text
        state = .awaitingAccept
        return [.none]
    }

    private mutating func handleNoSuggestion() -> [Effect] {
        guard state == .generating else { return [.none] }
        state = .idle
        ghost = ""
        return [.none]
    }

    private mutating func handleAcceptNextWord() -> [Effect] {
        guard state == .awaitingAccept, !ghost.isEmpty else { return [.none] }
        let segment = Self.nextWordSegment(ghost)
        guard !segment.isEmpty else { return [.none] }
        ghost = String(ghost.dropFirst(segment.count))
        if ghost.isEmpty {
            state = .idle
        } else {
            state = .awaitingAccept // keep the remainder for further stepping
        }
        return [.commit(segment)]
    }

    private mutating func handleAcceptAll() -> [Effect] {
        guard state == .awaitingAccept, !ghost.isEmpty else { return [.none] }
        let segment = ghost
        ghost = ""
        state = .idle
        return [.commit(segment)]
    }

    private mutating func handleDismissed() -> [Effect] {
        switch state {
        case .generating:
            // Dismiss while streaming: clear the streamed partial so the stale
            // ghost is not re-rendered by refresh after abort.
            state = .cooldown
            ghost = ""
            didEditDuringCooldown = false
            return [.cancelGeneration, .startCooldown]
        case .awaitingAccept:
            state = .cooldown
            ghost = ""
            didEditDuringCooldown = false
            return [.startCooldown]
        case .idle, .debouncing, .cooldown:
            return [.none]
        }
    }

    // MARK: - Segment helpers

    /// The "next word" of a ghost: leading whitespace + the first word + the
    /// whitespace run that follows it (so the caret ends up before the next
    /// word). Returns the whole ghost when there is no following word boundary.
    public static func nextWordSegment(_ ghost: String) -> String {
        var index = ghost.startIndex
        // Leading whitespace.
        while index < ghost.endIndex, ghost[index].isWhitespace {
            index = ghost.index(after: index)
        }
        // The word.
        while index < ghost.endIndex, !ghost[index].isWhitespace {
            index = ghost.index(after: index)
        }
        // Trailing whitespace run (the leading space of the next word).
        while index < ghost.endIndex, ghost[index].isWhitespace {
            index = ghost.index(after: index)
        }
        return String(ghost[ghost.startIndex..<index])
    }

    /// The remaining ghost after consuming the leading characters matched by
    /// `typed`, or nil if `typed` is a mismatch. Pure helper used by tests.
    static func consumeLeadingMatch(ghost: String, typed: String) -> String? {
        var remaining = ghost
        for ch in typed {
            guard ch == remaining.first else { return nil }
            remaining.removeFirst()
        }
        return remaining
    }
}
