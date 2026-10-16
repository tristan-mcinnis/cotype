import Foundation

/// How readable the focused Accessibility element is right now. The detector
/// uses this to "fail closed" on unknown/unreadable AX state rather than
/// guessing and potentially logging or completing in a secure context.
public enum AXReadState: String, Equatable, Sendable {
    /// The process is trusted for Accessibility and the focused element resolved.
    case readable
    /// The process is not trusted for Accessibility, so no element can be read.
    case untrusted
    /// The focused UI element could not be resolved (no element, no app, etc.).
    case elementUnresolvable
}

/// Why a context was classified as sensitive. Used both for the detector's
/// verdict and to label the reason in the Privacy & Data UI.
public enum SensitiveContextCategory: String, CaseIterable, Equatable, Sendable {
    /// The focused element is a secure text field (AX secure subrole).
    case secureTextField
    /// The focused element declares protected content (e.g. password managers).
    case protectedContent
    /// The frontmost app is on the built-in sensitive-app denylist.
    case sensitiveApp
    /// The frontmost app is on the user's exclusion list.
    case userExcludedApp
}

/// The detector's decision about a candidate context.
public enum SensitiveContextVerdict: Equatable, Sendable {
    /// Safe to complete and to log feedback.
    case safe
    /// Sensitive: never complete and never log.
    case gated(SensitiveContextCategory)
    /// Not readable: fail closed, do not complete or log.
    case unreadable
}

/// Error thrown by the pipeline when a context must not be completed. The
/// controller distinguishes this from a normal failure so it can surface a
/// privacy-appropriate message and record nothing.
public enum SensitiveContextError: Error, Equatable, Sendable {
    /// The context was detected as sensitive and must not be completed.
    case gated(SensitiveContextCategory)
    /// The focused text could not be read; fail closed.
    case unreadable
}

// MARK: - Focused-element ancestry (secure / protected ancestor walk)

/// Facts about a single AX element observed while walking the Accessibility
/// ancestry. `isReadable` is false when the element's attributes (or its parent
/// link) could not be read, so the ancestry cannot be established as
/// definitively safe — the detector must fail closed rather than guess.
public struct AXElementFacts: Equatable, Sendable {
    public var isSecureTextField: Bool
    public var containsProtectedContent: Bool
    public var isReadable: Bool

    public init(isSecureTextField: Bool, containsProtectedContent: Bool, isReadable: Bool) {
        self.isSecureTextField = isSecureTextField
        self.containsProtectedContent = containsProtectedContent
        self.isReadable = isReadable
    }
}

/// An opaque, hashable identity for an AX element during an ancestor walk. In
/// production this wraps a stable fingerprint of the live AX element; tests use
/// small integers. Equal tokens mean the same element (used for cycle
/// detection).
public struct AXAncestryToken: Hashable, Sendable {
    public let identity: UInt
    public init(identity: UInt) { self.identity = identity }
}

/// One step of an ancestor walk: the inspected element's facts plus the token of
/// its parent (nil = the ancestry naturally terminates here).
public struct AXAncestryStep: Equatable, Sendable {
    public var facts: AXElementFacts
    public var parent: AXAncestryToken?

    public init(facts: AXElementFacts, parent: AXAncestryToken? = nil) {
        self.facts = facts
        self.parent = parent
    }
}

/// Reads the secure/protected facts for an element and resolves its parent.
/// Injecting this makes the ancestor walk + policy unit-testable without a live
/// Accessibility tree.
public protocol AXAncestryReader {
    func readFacts(for element: AXAncestryToken) -> AXAncestryStep
}

/// Pure traversal + policy for the focused element and its Accessibility
/// ancestors. Fails closed (`.unreadable`) when the ancestry needed for a
/// definitive safety check cannot be read, exceeds a strict depth bound, or
/// cycles; gates when any ancestor (including the focused element) is a secure
/// text field or declares protected content; and returns `.safe` only when every
/// inspected element is readable and non-sensitive AND the chain terminates
/// naturally.
public enum SensitiveAncestryPolicy {
    /// A strict, small cap on how many ancestors to walk before refusing. Long
    /// enough to reach the window/app root for normal editors, short enough to
    /// bound a pathological or maliciously deep chain.
    public static let maxDepth = 24

    public static func evaluate(start: AXAncestryToken, reader: AXAncestryReader) -> SensitiveContextVerdict {
        var seen: Set<AXAncestryToken> = [start]
        var current = start
        var depth = 0
        while true {
            let step = reader.readFacts(for: current)
            guard step.facts.isReadable else {
                return .unreadable   // could not definitively read this element
            }
            if step.facts.isSecureTextField { return .gated(.secureTextField) }
            if step.facts.containsProtectedContent { return .gated(.protectedContent) }
            guard let parent = step.parent else {
                return .safe          // chain terminated naturally at the root
            }
            depth += 1
            if depth > maxDepth { return .unreadable }
            guard seen.insert(parent).inserted else { return .unreadable }   // cycle
            current = parent
        }
    }
}

/// Pure, testable classifier for "should Cotype refuse to complete here?"
///
/// The detector has no UI and no AX dependency — it is fed the minimum facts
/// the accessibility layer can observe, so it can be unit-tested with allow,
/// deny, and unknown/fail-closed states. It always fails closed:
///
/// - If the AX element is not readable, it returns `.unreadable` (never `.safe`).
/// - Secure text fields and protected content are always gated.
/// - The built-in sensitive-app denylist is always gated (non-overridable).
/// - User exclusions are always gated.
public struct SensitiveContextDetector: Sendable {

    /// Built-in denylist of application bundle identifiers that must never be
    /// completed or logged. This is a maintained, conservative list; user
    /// exclusions are additive and cannot re-enable a denylisted app.
    public static let builtInSensitiveApps: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.keychainaccess",
        "com.apple.security",
        "com.apple.Passwords",
        "com.agilebits.onepassword",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlane",
        "com.keepassxc.keepassxc",
        "com.bromium.browser",
    ]

    /// Apps the user has explicitly excluded in Privacy & Data. Applied in
    /// addition to (not in place of) the built-in denylist.
    public var userExclusions: Set<String>

    public init(userExclusions: Set<String> = []) {
        self.userExclusions = userExclusions
    }

    /// Classify a context. Fails closed on any unreadable or sensitive signal.
    ///
    /// - Parameter ancestry: the verdict from walking the focused element's
    ///   Accessibility ancestors (e.g. a nested secure/password container).
    ///   Defaults to `.safe` so callers that only inspect the focused element
    ///   keep their existing behavior.
    public func evaluate(
        appIdentifier: String,
        isSecureTextField: Bool,
        containsProtectedContent: Bool,
        axState: AXReadState,
        ancestry: SensitiveContextVerdict = .safe
    ) -> SensitiveContextVerdict {
        // Fail closed first: if we could not actually read the element, we must
        // not guess that it is safe to complete or log.
        guard axState == .readable else { return .unreadable }

        // A nested ancestor that is secure/protected, or an ancestry that could
        // not be read, gates/refuses before focusing only on this element.
        switch ancestry {
        case .safe: break
        case .gated(let category): return .gated(category)
        case .unreadable: return .unreadable
        }

        if isSecureTextField { return .gated(.secureTextField) }
        if containsProtectedContent { return .gated(.protectedContent) }
        if userExclusions.contains(appIdentifier) { return .gated(.userExcludedApp) }
        if Self.builtInSensitiveApps.contains(appIdentifier) { return .gated(.sensitiveApp) }

        return .safe
    }

    /// Whether a bundle identifier is on the built-in sensitive-app denylist.
    public static func isBuiltInSensitive(_ bundleID: String) -> Bool {
        builtInSensitiveApps.contains(bundleID)
    }
}
