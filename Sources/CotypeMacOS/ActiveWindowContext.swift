import AppKit
import ApplicationServices
import Foundation

/// Supplies bounded, in-memory context from the active window. Implementations
/// must never persist or log the returned text.
@MainActor
protocol ActiveWindowContextProviding {
    func context(in app: NSRunningApplication, excluding editor: AXUIElement) -> String
}

/// Pure normalization and bounding for visible-window text fragments.
enum ActiveWindowContextCompactor {
    static func compact(_ fragments: [String], maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        var seen = Set<String>()
        var normalized: [String] = []
        for fragment in fragments {
            let clean = fragment
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2, seen.insert(clean).inserted else { continue }
            normalized.append(clean)
        }

        let joined = normalized.joined(separator: "\n")
        guard joined.count > maxChars else { return joined }
        let tail = String(joined.suffix(maxChars))
        // Avoid beginning in the middle of a word when the bound cuts a long
        // active window. The most recent/lower window content remains intact.
        guard let boundary = tail.firstIndex(where: { $0.isWhitespace }) else { return tail }
        return String(tail[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads visible static text from the same active AX window as the focused
/// editor. This is deliberately not screenshot/OCR context: it uses the existing
/// Accessibility permission, excludes editable fields, skips secure/protected
/// subtrees, remains in memory, and is strictly bounded before prompting.
///
/// It is opt-in (`AXTextContextProvider.includeWindowContext`) and its budgets are
/// deliberately small: a second full-tree walk is expensive on large documents
/// and the focused-field text is what completion actually needs.
@MainActor
struct AXActiveWindowContextCollector: ActiveWindowContextProviding {
    var maxChars = 800
    var maxNodes = 250
    var maxDepth = 12

    func context(in app: NSRunningApplication, excluding editor: AXUIElement) -> String {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window: AXUIElement?
        if let editorWindow: AXUIElement = attributeValue(editor, kAXWindowAttribute) {
            window = editorWindow
        } else {
            window = attributeValue(appElement, kAXFocusedWindowAttribute)
        }
        guard let window else { return "" }
        return context(from: window, excluding: editor)
    }

    func context(from window: AXUIElement, excluding editor: AXUIElement) -> String {
        let editorIdentity = CFHash(editor)
        let windowFrame = AXFocusedEditorResolver.usableFrame(of: window)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = Set<CFHashCode>()
        var fragments: [String] = []

        while let next = stack.popLast(), visited.count < maxNodes {
            guard next.1 <= maxDepth else { continue }
            let element = next.0
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            if identity == editorIdentity { continue }
            if isSensitive(element) { continue }

            let role: String = attributeValue(element, kAXRoleAttribute) ?? ""
            if Self.contextRoles.contains(role), isVisible(element, inside: windowFrame),
               let text = readableText(element) {
                fragments.append(text)
            }

            guard next.1 < maxDepth,
                  let children: [AXUIElement] = attributeValue(element, kAXChildrenAttribute)
            else { continue }
            // Reverse so stack traversal preserves AX child/reading order.
            for child in children.reversed() {
                stack.append((child, next.1 + 1))
            }
        }

        return ActiveWindowContextCompactor.compact(fragments, maxChars: maxChars)
    }

    private static let contextRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXListItem", "AXCell",
    ]

    private func readableText(_ element: AXUIElement) -> String? {
        if let value: String = attributeValue(element, kAXValueAttribute), !value.isEmpty {
            return value
        }
        if let title: String = attributeValue(element, kAXTitleAttribute), !title.isEmpty {
            return title
        }
        return nil
    }

    private func isVisible(_ element: AXUIElement, inside windowFrame: CGRect?) -> Bool {
        if let hidden: Bool = booleanAttribute(element, kAXHiddenAttribute), hidden { return false }
        guard let windowFrame else { return true }
        guard let frame = AXFocusedEditorResolver.usableFrame(of: element) else { return false }
        return windowFrame.intersects(frame)
    }

    private func isSensitive(_ element: AXUIElement) -> Bool {
        let subrole: String = attributeValue(element, kAXSubroleAttribute) ?? ""
        if subrole == kAXSecureTextFieldSubrole { return true }
        guard let protected: Bool = booleanAttribute(
            element,
            NSAccessibility.Attribute.containsProtectedContent.rawValue
        ) else { return false }
        return protected
    }

    private func booleanAttribute(_ element: AXUIElement, _ key: String) -> Bool? {
        guard let value = attribute(element, key) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    private func attributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        attribute(element, key) as? T
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
}
