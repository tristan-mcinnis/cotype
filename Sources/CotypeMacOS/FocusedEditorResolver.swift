import AppKit
import ApplicationServices
import Foundation

/// Pure ranking facts for choosing the actual editor when an app reports a
/// container (commonly an Electron `AXGroup`) as its focused UI element.
struct AXEditorCandidateFacts: Equatable, Sendable {
    var role: String
    var isFocused: Bool
    var isEnabled: Bool
    var hasStringValue: Bool
    var hasSelection: Bool
    var selectedTextSettable: Bool
    var hasUsableFrame: Bool
    /// Distance below the reported focused element. The reported element itself
    /// is depth 0; the real editor inside a reported container is deeper. Used
    /// only to break a top-score tie, never to outrank a better score.
    var depth: Int = 0
}

/// Conservative selection policy: choose one uniquely best editable candidate,
/// otherwise fail closed. A tie is not guessed because insertion into the wrong
/// field is worse than withholding a completion.
enum AXEditorResolutionPolicy {
    static func chosenIndex(from candidates: [AXEditorCandidateFacts]) -> Int? {
        let scored = candidates.enumerated().compactMap { index, facts -> (Int, Int)? in
            guard facts.isEnabled, facts.hasStringValue, facts.hasUsableFrame else { return nil }
            let isTextRole = facts.role == kAXTextAreaRole || facts.role == kAXTextFieldRole
            guard isTextRole || facts.hasSelection || facts.selectedTextSettable else { return nil }

            var score = 0
            if isTextRole { score += 100 }
            if facts.isFocused { score += 50 }
            if facts.selectedTextSettable { score += 20 }
            if facts.hasSelection { score += 10 }
            score += 1 // readable string + usable frame, enforced above
            return (index, score)
        }
        guard let bestScore = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == bestScore }
        if winners.count == 1 { return winners[0].0 }

        // Equal top scores used to fail closed outright, which left apps that
        // expose several equally-scored editors (Ghostty, WeChat) with no
        // resolved element at all. The reported container's real editor is the
        // nearest one below it, so the unique *shallowest* winner is taken.
        // Ambiguity at the same shallowest depth is still not guessed: two
        // sibling editors are indistinguishable, and a wrong field is worse
        // than no completion.
        guard let shallowest = winners.map({ candidates[$0.0].depth }).min() else { return nil }
        let nearest = winners.filter { candidates[$0.0].depth == shallowest }
        return nearest.count == 1 ? nearest[0].0 : nil
    }
}

/// Pure read-gating policy for the AX tree walk. Only an element that could
/// itself be the editor deserves its `AXValue` read: every other node would be
/// rejected by the candidate filter anyway, so reading another app's text is a
/// privacy cost and an IPC cost with no possible benefit.
enum AXEditorReadPolicy {
    static func shouldReadTextValue(
        role: String,
        isFocused: Bool,
        hasSelection: Bool,
        selectedTextSettable: Bool
    ) -> Bool {
        role == kAXTextAreaRole
            || role == kAXTextFieldRole
            || isFocused
            || hasSelection
            || selectedTextSettable
    }

    /// Whether the element's `AXValue` is a string, when that is already
    /// known without copying it. A native text role that answers
    /// `AXNumberOfCharacters` holds a string value, so the whole document
    /// need not cross the AX connection just to learn its type; this runs on
    /// every streamed-token render guard and several times per accept. Any
    /// other node, or a text role without a character count, returns nil and
    /// the caller reads the value as before.
    static func knownStringValue(role: String, characterCount: Int?) -> Bool? {
        guard role == kAXTextAreaRole || role == kAXTextFieldRole,
              let characterCount, characterCount >= 0
        else { return nil }
        return true
    }
}

/// Pure seed-selection policy for the focus-source fallback chain. The app's own
/// reported focused element (`AXFocusedUIElement`) is authoritative; the
/// system-wide focused element is consulted only when the app level produced no
/// editor, and only when it belongs to the same process, so a stale or other-app
/// system-wide focus can never become the editor Cotype reads or writes.
enum AXFocusSeedPolicy {
    /// Whether a system-wide focused element may be used as the fallback seed.
    /// An unreadable pid fails closed.
    static func acceptsSystemWideSeed(seedPID: pid_t?, frontmostPID: pid_t) -> Bool {
        guard let seedPID else { return false }
        return seedPID == frontmostPID
    }

    /// The first provider that yields a value, in order. Providers after the
    /// first success are never invoked, so the system-wide AX read stays lazy on
    /// the common path.
    static func firstResolved<T>(_ providers: [() -> T?]) -> T? {
        for provider in providers {
            if let value = provider() { return value }
        }
        return nil
    }
}

/// Resolves the real focused editor rather than blindly trusting
/// `AXFocusedUIElement`. Chromium/Electron apps can focus a window-sized group
/// while the actual settable `AXTextArea` sits many levels below it. All Cotype
/// stages use this resolver so context, focus identity, rendering, and insertion
/// agree on one element.
enum AXFocusedEditorResolver {
    private static let maxNodes = 1_500
    private static let maxDepth = 40

    /// Resolves the frontmost app's editor, trying the app-level focused element
    /// first and the system-wide focused element second. The fallback lives here
    /// (not in each caller) so context, focus identity, rendering, and insertion
    /// all agree on one element and one fallback rule; the system-wide read stays
    /// lazy, so the common path pays nothing for it.
    static func resolve(in app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        if Thread.isMainThread {
            MainActor.assumeIsolated { AXWake.prepare(app) }
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let pid = app.processIdentifier

        return AXFocusSeedPolicy.firstResolved([
            {
                guard let reported: AXUIElement = attributeValue(appElement, kAXFocusedUIElementAttribute) else {
                    return nil
                }
                return resolve(from: reported)
            },
            {
                guard let systemSeed: AXUIElement = attributeValue(
                    AXUIElementCreateSystemWide(),
                    kAXFocusedUIElementAttribute
                ), AXFocusSeedPolicy.acceptsSystemWideSeed(
                    seedPID: processID(of: systemSeed),
                    frontmostPID: pid
                ) else { return nil }
                return resolve(from: systemSeed)
            },
        ])
    }

    static func resolve(from reported: AXUIElement) -> AXUIElement? {
        let reportedFacts = facts(for: reported, depth: 0)
        // Native editors correctly report the focused text element. Avoid a tree
        // walk on the overwhelmingly common path.
        if reportedFacts.isFocused,
           reportedFacts.isEnabled,
           reportedFacts.hasStringValue,
           reportedFacts.hasUsableFrame,
           reportedFacts.role == kAXTextAreaRole || reportedFacts.role == kAXTextFieldRole {
            return reported
        }

        // Breadth-first walk with an index cursor: `removeFirst()` on a growing
        // array is O(n) per node, making the traversal O(n²) on wide trees. The
        // cursor keeps it linear while preserving child order.
        var queue: [(element: AXUIElement, depth: Int)] = [(reported, 0)]
        var cursor = 0
        var visited = Set<CFHashCode>()
        var elements: [AXUIElement] = []
        var candidateFacts: [AXEditorCandidateFacts] = []

        while cursor < queue.count, visited.count < maxNodes {
            let next = queue[cursor]
            cursor += 1
            guard next.depth <= maxDepth else { continue }
            let identity = CFHash(next.element)
            guard visited.insert(identity).inserted else { continue }

            let nodeFacts = facts(for: next.element, depth: next.depth)
            if isPotentialCandidate(nodeFacts) {
                elements.append(next.element)
                candidateFacts.append(nodeFacts)
            }

            guard next.depth < maxDepth,
                  let children: [AXUIElement] = attributeValue(next.element, kAXChildrenAttribute)
            else { continue }
            queue.append(contentsOf: children.map { ($0, next.depth + 1) })
        }

        guard let index = AXEditorResolutionPolicy.chosenIndex(from: candidateFacts) else { return nil }
        return elements[index]
    }

    private static func isPotentialCandidate(_ facts: AXEditorCandidateFacts) -> Bool {
        facts.role == kAXTextAreaRole
            || facts.role == kAXTextFieldRole
            || facts.isFocused
            || facts.hasSelection
            || facts.selectedTextSettable
    }

    private static func facts(for element: AXUIElement, depth: Int) -> AXEditorCandidateFacts {
        let role: String = attributeValue(element, kAXRoleAttribute) ?? ""
        let enabled: Bool = booleanAttribute(element, kAXEnabledAttribute) ?? true
        let focused: Bool = booleanAttribute(element, kAXFocusedAttribute) ?? false
        let hasSelection = hasValidSelectionRange(element)

        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        let selectedTextSettable = settableError == .success && settable.boolValue

        // Read `AXValue` only for a node that could itself be the editor: a
        // text role, the focused element, or a node exposing a caret/
        // settability. Selection and settability are metadata, but the string
        // value is the user's text, so a container, label, or widget that the
        // candidate filter would reject anyway never has its value read.
        let couldBeEditor = AXEditorReadPolicy.shouldReadTextValue(
            role: role,
            isFocused: focused,
            hasSelection: hasSelection,
            selectedTextSettable: selectedTextSettable
        )
        let hasString: Bool
        if !couldBeEditor {
            hasString = false
        } else if let known = AXEditorReadPolicy.knownStringValue(
            role: role,
            characterCount: role == kAXTextAreaRole || role == kAXTextFieldRole
                ? characterCount(of: element) : nil
        ) {
            hasString = known
        } else {
            hasString = (attribute(element, kAXValueAttribute) as? String) != nil
        }

        return AXEditorCandidateFacts(
            role: role,
            isFocused: focused,
            isEnabled: enabled,
            hasStringValue: hasString,
            hasSelection: hasSelection,
            selectedTextSettable: selectedTextSettable,
            hasUsableFrame: usableFrame(of: element) != nil,
            depth: depth
        )
    }

    /// `AXNumberOfCharacters`, or nil when the element does not answer it.
    private static func characterCount(of element: AXUIElement) -> Int? {
        (attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }

    /// The pid that owns an AX element, or nil when it cannot be read.
    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func usableFrame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute),
              size.width > 0,
              size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func hasValidSelectionRange(_ element: AXUIElement) -> Bool {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return false }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return false }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range)
            && range.location >= 0
            && range.length >= 0
    }

    private static func booleanAttribute(_ element: AXUIElement, _ key: String) -> Bool? {
        guard let value = attribute(element, key) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func pointAttribute(_ element: AXUIElement, _ key: String) -> CGPoint? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement, _ key: String) -> CGSize? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func attributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        attribute(element, key) as? T
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
}
