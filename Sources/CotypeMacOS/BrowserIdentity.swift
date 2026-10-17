import Foundation
import AppKit
import ApplicationServices
import CotypeCore

/// Resolves the website a browser window is showing, for website rules.
///
/// The identity must be trustworthy before any rule can broaden or narrow the
/// app policy:
/// - it is read from the focused element's own `AXDocument`/`AXURL`, walking at
///   most a few ancestors to the web area;
/// - the window's document is read separately, and the two must agree when both
///   are readable;
/// - a resolved window that is not the app's focused window is refused;
/// - `WebsiteDomain.host(from:)` refuses non-http(s), user-info URLs and
///   single-label hosts.
///
/// Any disagreement or unreadable identity returns nil. Callers must treat nil
/// as "no website rule", never as permission.
public protocol BrowserDomainProviding: Sendable {
    /// The normalised host currently shown by the focused browser window, or
    /// nil when it cannot be established reliably.
    func currentDomain(appIdentifier: String) -> String?
}

/// Live Accessibility reader. Main-thread only, like every AX call.
public struct AXBrowserDomainProvider: BrowserDomainProviding {
    /// How far up from the focused element to look for `AXDocument`. Chromium
    /// exposes it on the web area a few levels above the editable node.
    public var maxAncestorDepth: Int

    public init(maxAncestorDepth: Int = 6) {
        self.maxAncestorDepth = maxAncestorDepth
    }

    public func currentDomain(appIdentifier: String) -> String? {
        guard AppCompatibility.isBrowser(appIdentifier) else { return nil }
        return MainActor.assumeIsolated { readDomain(appIdentifier: appIdentifier) }
    }

    @MainActor
    private func readDomain(appIdentifier: String) -> String? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == appIdentifier,
              let focused = AXFocusedEditorResolver.resolve(in: app)
        else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // The focused element must live in the app's focused window, otherwise
        // the document read below could describe a different window.
        let elementWindow = elementAttribute(focused, kAXWindowAttribute)
        let appFocusedWindow = elementAttribute(appElement, kAXFocusedWindowAttribute)
        if let focusedWindow = appFocusedWindow,
           let elementWindow,
           CFHash(focusedWindow) != CFHash(elementWindow) {
            return nil
        }

        let elementDocument = documentURL(startingAt: focused)
        let window = elementWindow ?? appFocusedWindow
        let windowDocument = window.flatMap { documentURL(startingAt: $0) }

        return BrowserDocumentIdentity.domain(
            elementDocument: elementDocument,
            windowDocument: windowDocument
        )
    }

    /// Read `AXDocument`, then `AXURL`, on the element and up to
    /// `maxAncestorDepth` ancestors. The first readable value wins; a malformed
    /// value stops the walk (ambiguous), not a fallback.
    @MainActor
    private func documentURL(startingAt element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth <= maxAncestorDepth {
            if let document = stringAttribute(node, kAXDocumentAttribute) { return document }
            if let url = stringAttribute(node, NSAccessibility.Attribute.url.rawValue) { return url }
            current = elementAttribute(node, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    @MainActor
    private func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        guard let value = attribute(element, key) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    /// A CFTypeRef attribute that is known to be an AX element. A malformed
    /// value is treated as absent.
    @MainActor
    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    @MainActor
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return error == .success ? value : nil
    }
}

/// A fixed provider for tests and for code paths that deliberately have no
/// browser identity.
public struct FixedBrowserDomainProvider: BrowserDomainProviding {
    public var host: String?

    public init(host: String? = nil) {
        self.host = host
    }

    public func currentDomain(appIdentifier: String) -> String? {
        guard AppCompatibility.isBrowser(appIdentifier) else { return nil }
        return host
    }
}
