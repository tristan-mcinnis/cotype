import Foundation

/// The exact identity of the focused editor target captured when a completion
/// is triggered.
///
/// The controller captures this once, at trigger time, alongside the app bundle
/// ID. It bundles the app ID with a window fingerprint and an element
/// fingerprint so a focus change *within* the same app (switching to another
/// field or window) is also detected — not just an app switch.
///
/// `windowIdentity`/`elementIdentity` are best-effort fingerprints derived from
/// the Accessibility element. They are used for *equality comparison* (did the
/// focused element change?) rather than as a stable global identifier, so the
/// safety guarantee is conservative: any change forces a cancellation and never
/// a wrong-target paste.
///
/// `selection` carries the caret/selection range (location + length) at capture
/// time, when the editor exposes it. It lets the guard reject an old candidate
/// after the caret moved *within the same element* (e.g. the user typed or moved
/// the insertion point while a completion was pending). `.unsupported` enables
/// element-only identity for editors that explicitly do not expose the range;
/// `nil` means the read failed and always fails closed.
public struct FocusTarget: Equatable, Sendable {
    /// A caret/selection anchor: the character location and length of the current
    /// selection (length 0 = a plain caret).
    public struct SelectionRange: Equatable, Sendable {
        public let location: Int
        public let length: Int
        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    /// The tri-state caret/selection identity of the focused editor.
    public enum Selection: Equatable, Sendable {
        /// The editor exposes a valid caret/selection range; it must match on re-read.
        case range(SelectionRange)
        /// The editor explicitly does not expose a selection range; element-only
        /// identity is acceptable (compat with editors that never surface a caret).
        case unsupported
    }

    /// Bundle identifier of the app owning the focused field (e.g. "com.apple.dt.Xcode").
    public let appIdentifier: String
    /// Fingerprint of the focused AX window (0 when no window could be resolved).
    public let windowIdentity: UInt
    /// Fingerprint of the focused AX element (0 when no element could be resolved).
    public let elementIdentity: UInt
    /// `nil` = the selection could not be read (fail closed); `.range` = must match
    /// on re-read; `.unsupported` = element-only (no caret to check).
    public let selection: Selection?

    /// Defaults to `selection: nil` (fail closed) so an omitted selection is never
    /// silently treated as element-only. Callers that genuinely have no caret
    /// (editor exposes no selection range) must pass `.unsupported` explicitly.
    public init(
        appIdentifier: String,
        windowIdentity: UInt,
        elementIdentity: UInt,
        selection: Selection? = nil
    ) {
        self.appIdentifier = appIdentifier
        self.windowIdentity = windowIdentity
        self.elementIdentity = elementIdentity
        self.selection = selection
    }

    /// The expected caret range after replacing the captured selection with
    /// `inserted`. AX ranges are measured in UTF-16 code units, so the new caret
    /// is `selection.location + inserted.utf16.count` with length 0 (an inserted
    /// text always leaves a plain caret, never a preserved selection).
    ///
    /// Callers refresh the expected range with this after a confirmed type-through
    /// or a successful segment insertion, so a multi-segment completion is not
    /// rejected when the caret legitimately advances. Returns nil when the target
    /// carries no caret range (nil selection or explicitly unsupported).
    public func expectedSelectionAfterInserting(_ inserted: String) -> SelectionRange? {
        guard case .range(let selection)? = self.selection else { return nil }
        let (location, overflow) = selection.location.addingReportingOverflow(inserted.utf16.count)
        guard !overflow else { return nil }
        return SelectionRange(location: location, length: 0)
    }
}

/// Pure policy for deciding whether a pending completion whose target was
/// captured at trigger time is still valid given the *current* focus.
///
/// Fails closed: it cancels on any change, including a same-app field/window
/// switch, AND when either the captured or the currently re-read focus target is
/// unavailable. There is no "unknown -> safe" fallback: if the exact focused
/// editor cannot be captured or re-read, we never render/accept/insert, so a
/// completion can never land in the wrong field.
public enum FocusIdentityPolicy {
    /// True only when both the captured and the current focus targets are known
    /// and identical. Any nil, or any mismatch, returns false.
    ///
    /// Caret semantics (fail closed):
    /// - A captured `.range` requires the current range to be present AND equal —
    ///   otherwise the caret moved within the same element, or it can no longer
    ///   be read (nil / unreadable), so the old candidate must not be committed.
    /// - A captured `.unsupported` (editor exposes no selection range) uses
    ///   element-only identity; a re-read error still fails because the current
    ///   target would be nil.
    /// - A nil captured selection means it could not be read (the provider already
    ///   failed closed by returning a nil target) — treated as fail closed here
    ///   defensively rather than silently degrading to element-only.
    public static func isValid(captured: FocusTarget?, current: FocusTarget?) -> Bool {
        guard let captured, let current else { return false }
        guard captured.appIdentifier == current.appIdentifier,
              captured.windowIdentity == current.windowIdentity,
              captured.elementIdentity == current.elementIdentity else {
            return false
        }
        switch captured.selection {
        case .range(let capturedRange):
            guard case .range(let currentRange)? = current.selection, currentRange == capturedRange else {
                return false
            }
            return true
        case .unsupported:
            // Captured element-only: the current target must still be element-only.
            // A newly-readable `.range` is a change in behavior -> fail closed.
            guard case .unsupported = current.selection else { return false }
            return true
        case nil:
            return false   // selection was unreadable at capture -> fail closed
        }
    }
}

/// Reads the currently focused editor's identity through the Accessibility API.
///
/// AX reads are main-thread-only, so the whole protocol is isolated to the main
/// actor. Callers that may be off-main (an inserter running in a background
/// `Task`) must hop with `MainActor.run` before calling.
@MainActor
public protocol FocusIdentityProvider {
    /// The currently focused target, or nil when it cannot be resolved.
    func currentFocusTarget() -> FocusTarget?
}

/// The outcome of a direct Accessibility text insertion attempt.
///
/// Only `.unsupported` is a clean "did not attempt / cannot do this" signal that
/// a caller may fall back to the pasteboard. `.failed` means `setSelectedText`
/// was attempted and its commit status is *ambiguous* — a pasteboard fallback
/// could duplicate the text — so a caller must surface an error and insert
/// nothing further.
public enum DirectInsertionOutcome: Equatable, Sendable {
    /// The text was committed directly into the focused element.
    case inserted
    /// The focused element cannot accept a direct AX insertion; the caller may
    /// fall back to the pasteboard route (text was not attempted/committed).
    case unsupported
    /// A direct write was attempted but its outcome could not be confirmed.
    /// The caller must NOT pasteboard-fallback (the text may already be
    /// committed); it should throw and insert nothing further.
    case failed
}

/// A strategy that inserts text directly into the focused editor through the
/// Accessibility API (no clipboard swap, no synthetic keypress).
///
/// The `CompletionInsertionRouter` calls this first for normal short
/// completions and falls back to the pasteboard when it reports `.unsupported`
/// or `.failed` (or when the text is long). AX reads are main-thread-only, so
/// the whole protocol is isolated to the main actor; callers hop with
/// `MainActor.run`.
@MainActor
public protocol DirectTextInserter {
    /// Insert `text` directly, re-validating the exact focused-editor target
    /// (`focusTarget`) so the operation is pinned to the element that was
    /// approved rather than whatever happens to be focused at write time.
    func insertDirect(_ text: String, appIdentifier: String, focusTarget: FocusTarget) -> DirectInsertionOutcome
}
