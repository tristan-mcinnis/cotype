import Foundation
import AppKit
import ApplicationServices
import CotypeCore

/// A `ContextProvider` that reads the frontmost app's focused text through the
/// macOS Accessibility (AX) API.
///
/// It captures whatever the user is currently editing (in Xcode, TextEdit,
/// browsers, terminals, etc.), splits it into the text before and after the
/// caret, and returns a `CompletionContext` the pipeline can build a prompt from.
///
/// Privacy posture (fail closed):
/// - If the process is not trusted for Accessibility, or the focused element
///   cannot be resolved, the provider throws `SensitiveContextError.unreadable`
///   rather than guessing — an unreadable context is never completed or logged.
/// - Before reading, it runs the configurable `SensitiveContextDetector`. Secure
///   text fields, protected content, the built-in sensitive-app denylist, and
///   user exclusions all gate the completion and prevent any log record.
/// - Every AX attribute is read defensively through optional-returning helpers.
public struct AXTextContextProvider: ContextProvider {

    /// Maximum prefix characters kept for the completion prompt. The whole
    /// document is read from Accessibility, but only the window nearest the
    /// caret (the trailing `maxPrefixChars`) is stored, so a long document's
    /// early lines never drown out the Gemma header structure or waste context.
    public var maxPrefixChars: Int
    /// Maximum suffix characters kept. The suffix is the text AFTER the caret, so
    /// the nearest-to-caret window is its leading `maxSuffixChars`. Capping it
    /// prevents a huge document suffix from overflowing the context / memory.
    public var maxSuffixChars: Int
    public var includeSelectedText: Bool
    /// Whether to read bounded visible text from the rest of the active window's
    /// AX tree (a separate tree walk). Off by default: the manual-first slice
    /// only needs the focused field, and each extra accessibility traversal costs
    /// latency the user can feel. Opt in via the `context.windowTree` default.
    public var includeWindowContext: Bool
    /// Classifier used to refuse secure/unknown contexts. Built from the user's
    /// current exclusions by the owner (the completion controller).
    public var sensitiveDetector: SensitiveContextDetector

    public init(
        maxPrefixChars: Int = 2000,
        maxSuffixChars: Int = 2000,
        includeSelectedText: Bool = true,
        includeWindowContext: Bool = false,
        sensitiveDetector: SensitiveContextDetector = SensitiveContextDetector()
    ) {
        self.maxPrefixChars = maxPrefixChars
        self.maxSuffixChars = maxSuffixChars
        self.includeSelectedText = includeSelectedText
        self.includeWindowContext = includeWindowContext
        self.sensitiveDetector = sensitiveDetector
    }

    public func provideContext(for request: CompletionRequest) async throws -> CompletionContext {
        // AX reads are thread-sensitive: hop onto the main actor for the actual
        // attribute lookups, then hand the plain value back to the caller.
        try await MainActor.run { try readContext(for: request) }
    }

    @MainActor
    private func readContext(for request: CompletionRequest) throws -> CompletionContext {
        guard AXIsProcessTrusted() else {
            throw SensitiveContextError.unreadable
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SensitiveContextError.unreadable
        }

        let bundleID = app.bundleIdentifier ?? "unknown"

        // Resolve the real editor, not merely the element the app reports as
        // focused. Electron apps can focus a window-sized AXGroup while their
        // settable AXTextArea lives many levels below it. The app-level then
        // system-wide seed fallback lives inside the resolver so every stage
        // (context, focus identity, rendering, insertion) picks the same element.
        guard let focusedElement = AXFocusedEditorResolver.resolve(in: app) else {
            throw SensitiveContextError.unreadable
        }

        let axState = AXReadState.readable
        let isSecureTF = isSecureTextElement(focusedElement)
        let hasProtectedContent = containsProtectedContent(focusedElement)

        // Also walk the focused element's Accessibility ancestors for a nested
        // secure text field / protected container. Failing closed on an unreadable
        // ancestry means a sensitive container is never completed even when the
        // focused element itself looks like ordinary text.
        let ancestryVerdict = SensitiveAncestryPolicy.evaluate(
            start: AXAncestryToken(identity: CFHash(focusedElement)),
            reader: LiveAXAncestryReader(focusedElement: focusedElement)
        )

        // Fail closed: never complete or log a secure/unknown context.
        switch sensitiveDetector.evaluate(
            appIdentifier: bundleID,
            isSecureTextField: isSecureTF,
            containsProtectedContent: hasProtectedContent,
            axState: axState,
            ancestry: ancestryVerdict
        ) {
        case .safe:
            break
        case .gated(let category):
            throw SensitiveContextError.gated(category)
        case .unreadable:
            throw SensitiveContextError.unreadable
        }

        // A focused element without a readable string value is not a safe text
        // context. Do not turn an AX read failure into an empty prompt, since
        // that would bypass the fail-closed guarantee and could still generate
        // or record a completion for an unknown element.
        guard let text = attributeValue(focusedElement, kAXValueAttribute) as String? else {
            throw SensitiveContextError.unreadable
        }

        // Split text into prefix (before the caret) and suffix (after it), using
        // the same tri-state selection decoder as the commit-time focus guard.
        // Only an explicitly unsupported range permits the whole-value fallback;
        // a transient read error or malformed range fails closed.
        let contextRange: CFRange?
        if AppCompatibility.isTerminal(bundleID) {
            // Terminals report the selection at 0 whatever the cursor does; the
            // caret is inferred from the user's own keys (TerminalCaret).
            guard let offset = TerminalCaret.caretOffset(forScreen: text) else {
                throw SensitiveContextError.unreadable
            }
            contextRange = CFRange(location: offset, length: 0)
        } else {
            switch AXFocusIdentityProvider.decodeSelectionRange(focusedElement) {
            case .range(let range):
                contextRange = CFRange(location: range.location, length: range.length)
            case .unsupported:
                contextRange = nil
            case .unavailable:
                throw SensitiveContextError.unreadable
            }
        }
        guard let split = ContextSplit.split(text, range: contextRange) else {
            throw SensitiveContextError.unreadable
        }
        let (prefix, suffix) = (split.prefix, split.suffix)

        let selected = attributeValue(focusedElement, kAXSelectedTextAttribute) as String? ?? ""

        var extra = request.extra
        extra["appName"] = app.localizedName ?? ""
        // Bounded, in-memory, same-window static text only when the user opted in.
        // The collector itself skips secure/protected subtrees and is capped by
        // its own budgets, so a disabled tree walk costs nothing at all.
        if includeWindowContext {
            let windowContext = AXActiveWindowContextCollector().context(
                in: app,
                excluding: focusedElement
            )
            if !windowContext.isEmpty {
                extra["windowContext"] = windowContext
            }
        }
        if includeSelectedText, !selected.isEmpty {
            extra["selectedText"] = selected
        }

        return CompletionContext(
            prefix: ContextWindow.nearestCaret(prefix: prefix, maxChars: maxPrefixChars),
            suffix: ContextWindow.nearestCaretSuffix(suffix, maxChars: maxSuffixChars),
            language: request.language,
            appIdentifier: bundleID,
            documentURL: request.documentURL,
            extra: extra
        )
    }

    // MARK: - Ancestry reader

    // MARK: - Sensitive detection

    /// Whether the focused element is a secure text field (e.g. a password
    /// field), read from its AX subrole. Fails toward "not secure" only because
    /// a missing subrole is a normal attribute absence; the detector still
    /// refuses when the element is unreadable as a whole.
    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        guard let subrole = attributeValue(element, kAXSubroleAttribute) as String? else { return false }
        return subrole == kAXSecureTextFieldSubrole
    }

    /// Whether the focused element declares protected content, per the AX
    /// `containsProtectedContent` attribute (password managers, secure fields).
    /// Reads as a CFBoolean to avoid a lossy Objective-C cast.
    private func containsProtectedContent(_ element: AXUIElement) -> Bool {
        guard let value = attribute(element, NSAccessibility.Attribute.containsProtectedContent.rawValue) else {
            return false
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    // MARK: - Helpers

    /// Read a single AX attribute, returning nil on any error or missing value.
    /// The attribute constants (e.g. `kAXValueAttribute`) are bridged to Swift as
    /// `String`, so we convert to `CFString` for the C API.
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return error == .success ? value : nil
    }

    /// Read a single AX attribute and cast the result to a specific type.
    /// Using a generic avoids the conditional-downcast-to-CF-type warning/error
    /// that a direct `as?` on `AXUIElement` / `AXValue` triggers.
    private func attributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        guard let value = attribute(element, key) else { return nil }
        return value as? T
    }

}

/// `AXAncestryReader` backed by the live Accessibility tree. Starts at the
/// focused element and walks `kAXParentAttribute`. Best-effort: a *missing*
/// subrole/protected attribute is treated as "not sensitive" (a normal absence,
/// matching the per-element helpers), but a read that returns an AX error —
/// including a failed parent lookup — is reported as unreadable so the ancestry
/// policy fails closed rather than completing in an unverifiable context.
///
/// Main-thread only (AX reads); the provider invokes it from its `@MainActor`
/// read path.
final class LiveAXAncestryReader: AXAncestryReader {
    private var elementsByToken: [AXAncestryToken: AXUIElement]

    init(focusedElement: AXUIElement) {
        let token = AXAncestryToken(identity: CFHash(focusedElement))
        self.elementsByToken = [token: focusedElement]
    }

    func readFacts(for element: AXAncestryToken) -> AXAncestryStep {
        guard let axElement = elementsByToken[element] else {
            // A token we never registered: cannot read it.
            return AXAncestryStep(
                facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false)
            )
        }

        let subrole = readAttribute(axElement, kAXSubroleAttribute)
        let protected = readAttribute(axElement, NSAccessibility.Attribute.containsProtectedContent.rawValue)
        let parent = readAttribute(axElement, kAXParentAttribute)

        // Optional attributes (subrole, containsProtectedContent) that are simply
        // unsupported or have no value are safely ABSENT (not secure/protected) —
        // exactly like a missing attribute on the focused element. Only a genuine
        // transport/permission error is unreadable.
        let isSecure: Bool
        switch subrole {
        case .value(let v):
            if v == nil { isSecure = false }
            else if let str = v as? String { isSecure = str == kAXSecureTextFieldSubrole }
            else {
                // Present but malformed (not a string) -> fail closed, not "not secure".
                return AXAncestryStep(facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false))
            }
        case .noValue, .unsupported: isSecure = false
        case .unreadable:
            return AXAncestryStep(facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false))
        }
        let isProtected: Bool
        switch protected {
        case .value(let v):
            if let b = booleanValue(v) { isProtected = b }
            else {
                // Present but malformed -> fail closed, not "not protected".
                return AXAncestryStep(facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false))
            }
        case .noValue, .unsupported: isProtected = false
        case .unreadable:
            return AXAncestryStep(facts: AXElementFacts(isSecureTextField: false, containsProtectedContent: false, isReadable: false))
        }

        switch parent {
        case .unreadable:
            // Cannot resolve the parent -> the ancestry is not definitively safe.
            return AXAncestryStep(facts: AXElementFacts(isSecureTextField: isSecure, containsProtectedContent: isProtected, isReadable: false))
        case .noValue, .value(nil):
            // A successful absent parent (or an explicit no-value) is a natural
            // root termination -> safe.
            return AXAncestryStep(facts: AXElementFacts(isSecureTextField: isSecure, containsProtectedContent: isProtected, isReadable: true))
        case .value(let rawParent):
            // A present parent value must be an AXUIElement; a malformed value is
            // a failed read, not a safe root.
            guard CFGetTypeID(rawParent) == AXUIElementGetTypeID() else {
                return AXAncestryStep(facts: AXElementFacts(isSecureTextField: isSecure, containsProtectedContent: isProtected, isReadable: false))
            }
            let parentElement = rawParent as! AXUIElement
            let parentToken = AXAncestryToken(identity: CFHash(parentElement))
            elementsByToken[parentToken] = parentElement
            return AXAncestryStep(facts: AXElementFacts(isSecureTextField: isSecure, containsProtectedContent: isProtected, isReadable: true), parent: parentToken)
        case .unsupported:
            // A parent lookup the element does not support usually means a root
            // (application / system-wide). Only accept that for known root roles;
            // otherwise fail closed.
            if Self.knownRootRoles.contains(elementRole(of: axElement)) {
                return AXAncestryStep(facts: AXElementFacts(isSecureTextField: isSecure, containsProtectedContent: isProtected, isReadable: true))
            }
            return AXAncestryStep(facts: AXElementFacts(isSecureTextField: isSecure, containsProtectedContent: isProtected, isReadable: false))
        }
    }

    /// How a single attribute read should be treated by the ancestry walk.
    enum AttributeRead {
        case value(CFTypeRef?)
        case noValue
        case unsupported
        case unreadable
    }

    /// Maps an AXError to how the ancestry reader should treat the read. Kept
    /// pure (and static) so the optional-vs-fatal classification is testable.
    static func categorize(_ error: AXError) -> AttributeRead {
        switch error {
        case .success: return .value(nil)   // value filled separately
        case .noValue: return .noValue
        case .attributeUnsupported, .parameterizedAttributeUnsupported: return .unsupported
        default: return .unreadable
        }
    }

    /// Read a single AX attribute, categorizing optional-absence vs. fatal error.
    private func readAttribute(_ element: AXUIElement, _ key: String) -> AttributeRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        switch error {
        case .success: return .value(value)
        default: return Self.categorize(error)
        }
    }

    /// Role names that are legitimate tree roots whose parent is unsupported.
    private static let knownRootRoles: Set<String> = [kAXApplicationRole, kAXSystemWideRole]

    private func elementRole(of element: AXUIElement) -> String {
        guard case .value(let v) = readAttribute(element, kAXRoleAttribute), let role = v as? String else { return "" }
        return role
    }

    private func booleanValue(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return false }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        if let n = value as? NSNumber { return n.boolValue }
        return nil   // present but malformed -> caller fails closed
    }
}

/// Pure, overflow-safe caret/context splitter. Given the focused editor text and
/// the selected-range (caret/selection), it computes the text before the caret
/// (prefix) and after the selection (suffix).
///
/// - A nil range (the editor does not expose one) returns the whole text as
///   prefix with no suffix, matching the historical fallback.
/// - A valid range is split with overflow-safe `addingReportingOverflow`.
/// - A malformed range (negative location/length, a caret or selection beyond
///   the document, or an overflowing location+length) returns nil so the caller
///   fails closed rather than treating the whole document as prefix.
enum ContextSplit {
    static func split(_ text: String, range: CFRange?) -> (prefix: String, suffix: String)? {
        let nsText = text as NSString
        guard let range else { return (text, "") }

        guard range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard !overflow,
              range.location <= nsText.length,
              end <= nsText.length else { return nil }

        return (nsText.substring(to: range.location), nsText.substring(from: end))
    }
}
