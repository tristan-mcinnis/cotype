import Foundation
import AppKit
import ApplicationServices
import CotypeCore

/// A pinned Accessibility editor element. All operations target the SAME element,
/// resolved once at pin time, so a focus change between calls cannot redirect a
/// write to a different field. AX reads/writes are main-thread-only.
@MainActor
public protocol AXEditorSession {
    /// The caret/selection range, or nil when unavailable or invalid.
    func selectedRange() -> CFRange?
    /// Whether the pinned editor accepts a selected-text write.
    func isSelectedTextSettable() -> Bool
    /// Replace the current selection with `text`. Returns false on failure.
    func setSelectedText(_ text: String) -> Bool
    /// Move the caret/selection to `range`. Returns false when unsupported.
    func setSelectedRange(_ range: CFRange) -> Bool
}

/// The Accessibility editor operations a direct text insertion needs, injected
/// so the pin/transact decision is testable without a live AX element.
///
/// Rather than re-resolving the focused element on every call (which a focus
/// change can redirect), a caller first pins the currently focused element and
/// validates it against the expected `FocusTarget`, then performs all operations
/// on the returned session — all bound to that one element. If the element cannot
/// be pinned or proven to match, pin returns nil and the caller must not write.
@MainActor
public protocol AXEditorTextOps {
    /// Pin the currently focused editor element (resolving it once) after proving
    /// it matches `expected`. Returns a session bound to that exact element, or
    /// nil when no element can be pinned or it cannot be proven to match
    /// `expected` (fail closed: the caller must not write).
    func pin(matching expected: FocusTarget) -> (any AXEditorSession)?
}

/// Production `AXEditorTextOps` backed by the live frontmost app's focused
/// element. Pin resolves the element once, validates it against the approved
/// identity, and returns a session bound to that exact element.
@MainActor
public struct LiveAXEditorTextOps: AXEditorTextOps {
    public init() {}

    public func pin(matching expected: FocusTarget) -> (any AXEditorSession)? {
        guard let focused = focusedElement(),
              let target = focusTarget(for: focused) else { return nil }
        // Fail closed unless the pinned element provably matches the approved
        // identity (app + window + element + caret range). A same-app field switch
        // or caret move since the router revalidation makes this nil.
        guard FocusIdentityPolicy.isValid(captured: expected, current: target) else { return nil }
        return LiveAXEditorSession(element: focused)
    }

    private func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXFocusedEditorResolver.resolve(in: app)
    }

    /// Build the FocusTarget for a resolved focused element using the same facts
    /// the focus guard uses (app + window + element fingerprints + caret range),
    /// so pin can prove the pinned element still matches the approved identity.
    private func focusTarget(for element: AXUIElement) -> FocusTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        let window = (axAttributeValue(element, kAXWindowAttribute) as AXUIElement?) ?? element
        let selection: FocusTarget.Selection
        switch AXFocusIdentityProvider.decodeSelectionRange(element) {
        case .range(let r): selection = .range(r)
        case .unsupported: selection = .unsupported
        case .unavailable: return nil
        }
        return FocusTarget(
            appIdentifier: bundleID,
            windowIdentity: AXFocusIdentityProvider.windowSignature(pid: app.processIdentifier, window: window),
            elementIdentity: AXFocusIdentityProvider.elementSignature(pid: app.processIdentifier, element: element),
            selection: selection
        )
    }

    private func axAttributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard error == .success, let value else { return nil }
        return value as? T
    }
}

/// Session bound to a single pinned AX element. Every operation uses that exact
/// element (no re-resolve), so a focus change between calls never redirects a
/// write to a different field.
@MainActor
struct LiveAXEditorSession: AXEditorSession {
    let element: AXUIElement

    func selectedRange() -> CFRange? {
        guard let axValue = axAttributeValue(element, kAXSelectedTextRangeAttribute) as AXValue?,
              AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    func isSelectedTextSettable() -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    func setSelectedText(_ text: String) -> Bool {
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    func setSelectedRange(_ range: CFRange) -> Bool {
        var r = range
        guard let axValue = AXValueCreate(.cfRange, &r) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    private func axAttributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard error == .success, let value else { return nil }
        return value as? T
    }
}

/// Direct AX text inserter. Inserts a completion by replacing the focused
/// editor's *selected* text (the minimal-mutation path) rather than rewriting the
/// whole `kAXValueAttribute`, so rich formatting and concurrent edits are left
/// untouched. Best-effort: returns `.unsupported` when the element does not
/// accept a selected-text write or the caret cannot be resolved, so the router
/// falls back to the pasteboard. `.failed` means a selected-text write was
/// attempted but its outcome is ambiguous — a caller must surface an error and
/// NOT pasteboard-fallback, since the text may already be committed. It never
/// touches the clipboard or the editor's full value.
@MainActor
public struct AXDirectTextInserter: DirectTextInserter {
    private let ops: AXEditorTextOps

    public init(ops: AXEditorTextOps? = nil) {
        self.ops = ops ?? LiveAXEditorTextOps()
    }

    public func insertDirect(_ text: String, appIdentifier: String, focusTarget: FocusTarget) -> DirectInsertionOutcome {
        // Pin the focused element and prove it still matches the approved target
        // BEFORE any mutation. A focus change since the router revalidation makes
        // pin return nil -> unsupported (fail closed, never write).
        guard let session = ops.pin(matching: focusTarget) else { return .unsupported }
        // Settability is checked BEFORE the final caret read so the read happens as
        // late as possible (immediately before the write).
        guard session.isSelectedTextSettable() else { return .unsupported }
        // Re-read the caret immediately before writing; it must STILL equal the
        // approved range — a caret that moved within the pinned element after pin is
        // a mismatch and we fail closed (only `.unsupported`/no-range fall back).
        guard let range = session.selectedRange(), range.location >= 0, range.length >= 0 else { return .unsupported }
        guard matchesApproved(range, focusTarget.selection) else { return .unsupported }
        let textLength = (text as NSString).length
        let (insertionEnd, overflow) = range.location.addingReportingOverflow(textLength)
        guard !overflow else { return .unsupported }
        guard session.setSelectedText(text) else { return .failed }
        // Restore the caret after the inserted text only when supported. This is
        // best-effort: the text is already inserted; a failed caret move is not a
        // failure of the insertion itself.
        _ = session.setSelectedRange(CFRange(location: insertionEnd, length: 0))
        return .inserted
    }

    /// Whether the freshly re-read caret exactly matches the approved `.range`.
    /// A `.unsupported` / nil approved selection (no caret to verify) falls back:
    /// we do not do a minimal-mutation direct insert without a verified caret.
    private func matchesApproved(_ range: CFRange, _ approved: FocusTarget.Selection?) -> Bool {
        guard case .range(let a)? = approved else { return false }
        return range.location == a.location && range.length == a.length
    }
}

/// The default `CompletionInserter`: routes a normal, short completion to direct
/// Accessibility insertion when the focused element supports it, and falls back
/// to the pasteboard Cmd+V route for incompatible or long fields.
///
/// Safety guarantees layered on top of the pasteboard route:
/// - The focused-field identity captured at trigger time is re-verified in the
///   same synchronous main-actor turn as the direct AX insertion, so the final
///   identity check and the insertion cannot straddle a focus change. If the
///   window/field/app changed (including a same-app change), it throws
///   `InsertionError.targetChanged` and never inserts into the wrong target.
/// - Only `.unsupported` may fall back to the pasteboard route. `.failed` means
///   the write was attempted with an ambiguous commit state, so it throws
///   `InsertionError.directInsertFailed` and inserts nothing further (a
///   pasteboard retry could duplicate the text).
/// - The pasteboard route (which itself re-verifies the app and restores the
///   clipboard only when the change count is unchanged) is used only as an
///   explicit fallback for `.unsupported` or long completions.
public struct CompletionInsertionRouter: CompletionInserter {

    /// The outcome of the single main-actor turn that re-verifies focus and,
    /// when applicable, attempts direct AX insertion. Kept local so the final
    /// identity check and the insertion cannot be separated by an await.
    private enum Route {
        case inserted
        case pasteboard
        case targetChanged
        case directFailed
    }

    /// Text longer than this is never inserted directly; it goes straight to the
    /// pasteboard. Direct AX selected-text set of a huge completion is slow and
    /// can drop formatting, so long completions use the (formatting-preserving)
    /// paste path.
    public var maxDirectTextLength: Int

    /// Stored as optionals so the `@MainActor` production defaults
    /// (`AXFocusIdentityProvider()`, `AXDirectTextInserter()`) are created
    /// lazily inside a main-actor closure rather than in this nonisolated init.
    private let focusIdentityProvider: FocusIdentityProvider?
    private let directInserter: DirectTextInserter?
    private let pasteboardInserter: CompletionInserter

    public init(
        maxDirectTextLength: Int = 512,
        focusIdentityProvider: FocusIdentityProvider? = nil,
        directInserter: DirectTextInserter? = nil,
        pasteboardInserter: CompletionInserter = PasteboardInserter()
    ) {
        self.maxDirectTextLength = maxDirectTextLength
        self.focusIdentityProvider = focusIdentityProvider
        self.directInserter = directInserter
        self.pasteboardInserter = pasteboardInserter
    }

    public func insert(_ text: String) async throws {
        try await insert(text, appIdentifier: nil, focusTarget: nil)
    }

    public func insert(_ text: String, appIdentifier: String?) async throws {
        try await insert(text, appIdentifier: appIdentifier, focusTarget: nil)
    }

    public func insert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws {
        // Fail closed: without an exact focused-field identity we never insert
        // into an unknown target.
        guard let focusTarget else { throw InsertionError.targetChanged }

        let shouldTryDirect = appIdentifier != nil && text.count <= maxDirectTextLength

        // Do the final FocusTarget re-validation AND the direct AX insertion in
        // ONE synchronous MainActor.run turn, so the identity check and the
        // insertion cannot straddle a focus change. Direct insertion only runs
        // when the captured identity still matches the live focus.
        let route = await MainActor.run { () -> Route in
            let provider = focusIdentityProvider ?? AXFocusIdentityProvider()
            guard FocusIdentityPolicy.isValid(captured: focusTarget, current: provider.currentFocusTarget()) else {
                return .targetChanged
            }
            if let appIdentifier, AppCompatibility.isTerminal(appIdentifier) {
                // Terminals take neither AX insertion nor a clean paste.
                KeystrokeTyper.type(text)
                return .inserted
            }
            guard shouldTryDirect, let appIdentifier else { return .pasteboard }
            let direct = directInserter ?? AXDirectTextInserter()
            switch direct.insertDirect(text, appIdentifier: appIdentifier, focusTarget: focusTarget) {
            case .inserted: return .inserted
            case .unsupported: return .pasteboard   // only .unsupported may fall back
            case .failed: return .directFailed       // ambiguous commit: never retry via paste
            }
        }

        switch route {
        case .inserted:
            return
        case .pasteboard:
            // Thread the captured FocusTarget into the pasteboard fallback so it
            // re-verifies the exact focused field immediately before Cmd+V (a
            // same-app field switch during clipboard preparation is caught).
            try await pasteboardInserter.insert(text, appIdentifier: appIdentifier, focusTarget: focusTarget)
        case .targetChanged:
            throw InsertionError.targetChanged
        case .directFailed:
            throw InsertionError.directInsertFailed
        }
    }
}
