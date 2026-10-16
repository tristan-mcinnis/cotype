import Foundation
import AppKit
import ApplicationServices
import CotypeCore

// MARK: - Insertion target verifier (focus guard)

/// The seam that re-checks, immediately before pasting, that the focused editor
/// is still the app we captured context from. This is what prevents ever
/// pasting into the wrong app after a focus change.
public protocol InsertionTargetVerifier {
    /// Returns true when it is safe to insert into `appIdentifier` (the app we
    /// originally captured the completion context from).
    @MainActor
    func verifyTarget(appIdentifier: String) -> Bool
}

/// Production verifier: the frontmost app must be unchanged and Cotype must
/// still be trusted for Accessibility.
public struct AXInsertionTargetVerifier: InsertionTargetVerifier {
    public init() {}

    @MainActor
    public func verifyTarget(appIdentifier: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        return frontmost == appIdentifier
    }
}

/// A verifier that always reports safe — used when only the pasteboard itself
/// must be guarded (e.g. in tests) or when the target is unknown.
public struct UnconditionalTargetVerifier: InsertionTargetVerifier {
    public init() {}
    @MainActor public func verifyTarget(appIdentifier: String) -> Bool { true }
}

/// Verifies against an injected sequence of results. Test seam.
public final class StubTargetVerifier: InsertionTargetVerifier, @unchecked Sendable {
    private let results: [Bool]
    private var index = 0
    public init(_ results: [Bool]) { self.results = results }
    @MainActor public func verifyTarget(appIdentifier: String) -> Bool {
        defer { index = min(index + 1, results.count) }
        return results[min(index, results.count - 1)]
    }
}

// MARK: - Focused-field identity provider (full element/window capture)

/// Production adapter that resolves the frontmost app's focused element and
/// window into a `FocusTarget`. Returns nil on any lookup failure so callers
/// fail closed rather than degrading to a coarser app-only guard.
///
/// The identity is a *fingerprint* (process, role, and window frame; see
/// `elementSignature`).
/// Two AX element wrappers for the same underlying server-side element compare
/// equal and hash alike, while a focus switch to a different field or window
/// yields a different element and therefore a different fingerprint — which is
/// exactly what the focus guard needs.
@MainActor
public struct AXFocusIdentityProvider: FocusIdentityProvider {
    public init() {}

    public func currentFocusTarget() -> FocusTarget? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return nil
        }

        guard let focused = AXFocusedEditorResolver.resolve(in: app) else {
            return nil
        }

        let window = (axAttributeValue(focused, kAXWindowAttribute) as AXUIElement?) ?? focused

        // Fail closed on an unreadable selection range (it is part of the exact
        // commit target). Only an explicit attributeUnsupported falls back to
        // element-only; a noValue / malformed / transport error makes the
        // identity unavailable and returns a nil target.
        let selection: FocusTarget.Selection
        switch Self.decodeSelectionRange(focused) {
        case .range(let r): selection = .range(r)
        case .unsupported: selection = .unsupported
        case .unavailable: return nil
        }

        return FocusTarget(
            appIdentifier: bundleID,
            windowIdentity: Self.windowSignature(pid: app.processIdentifier, window: window),
            elementIdentity: Self.elementSignature(pid: app.processIdentifier, element: focused),
            selection: selection
        )
    }

    /// Stable identity for the focused editor. `CFHash` of an AXUIElement is not
    /// stable in Chromium/Electron: they hand out a new node token on each read
    /// (cotabby keys focus identity on process + role for this reason), so the
    /// old hash made every Slack/Helium suggestion fail its own focus check.
    /// The exact caret range, compared separately, still pins the position.
    static func elementSignature(pid: pid_t, element: AXUIElement) -> UInt {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(stringAttribute(element, kAXRoleAttribute))
        hasher.combine(stringAttribute(element, kAXSubroleAttribute))
        hasher.combine(stringAttribute(element, "AXDOMIdentifier"))
        return UInt(bitPattern: hasher.finalize())
    }

    /// Stable identity for the focused window: process plus its frame rounded
    /// to 8 pt, so a different window of the same app does not match.
    static func windowSignature(pid: pid_t, window: AXUIElement) -> UInt {
        var hasher = Hasher()
        hasher.combine(pid)
        if let frame = AXFocusedEditorResolver.usableFrame(of: window) {
            hasher.combine(Int(frame.minX / 8))
            hasher.combine(Int(frame.minY / 8))
            hasher.combine(Int(frame.width / 8))
            hasher.combine(Int(frame.height / 8))
        }
        return UInt(bitPattern: hasher.finalize())
    }

    private static func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axAttributeValue<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard error == .success, let value else { return nil }
        return value as? T
    }

    /// Read the focused element's selected-range attribute and decode it.
    static func decodeSelectionRange(_ element: AXUIElement) -> SelectedRangeRead {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rawValue)
        return decodeSelectionRange(error: error, value: rawValue)
    }

    /// Pure tri-state decode so tests can separate explicit attributeUnsupported
    /// from genuine errors / malformed values without a live AX element.
    static func decodeSelectionRange(error: AXError, value: CFTypeRef?) -> SelectedRangeRead {
        switch error {
        case .success:
            guard let v = value, CFGetTypeID(v) == AXValueGetTypeID() else {
                return .unavailable   // malformed / non-AXValue value
            }
            let axValue = v as! AXValue
            guard AXValueGetType(axValue) == .cfRange else { return .unavailable }
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return .unavailable }
            return .range(FocusTarget.SelectionRange(location: range.location, length: range.length))
        case .attributeUnsupported, .parameterizedAttributeUnsupported:
            return .unsupported
        default:
            // noValue, cannotComplete, invalidUIElement, failure, notImplemented, ...
            return .unavailable
        }
    }
}

/// The tri-state result of reading the focused editor's caret/selection range.
enum SelectedRangeRead {
    case range(FocusTarget.SelectionRange)
    /// The attribute is explicitly unsupported by this element; element-only.
    case unsupported
    /// noValue / malformed value / transport or permission error — identity
    /// unavailable, fail closed.
    case unavailable
}

/// Stub provider for tests: returns an injectable, mutable current target.
/// Conforms to the `@MainActor` `FocusIdentityProvider`; all state is accessed
/// on the main actor (the conformance is explicitly isolated, not suppressed).
@MainActor
public final class StubFocusIdentityProvider: FocusIdentityProvider {
    public var current: FocusTarget?
    public init(_ current: FocusTarget? = nil) { self.current = current }
    public func currentFocusTarget() -> FocusTarget? { current }
}

// MARK: - Pure focus-change guard

/// Pure policy for deciding whether a pending completion must be cancelled
/// because the user switched apps. The controller is the only observer, but the
/// decision is kept pure and testable here.
public enum FocusGuardPolicy {
    /// `activeAppIdentifier` is the app Cotype captured context from. If the
    /// frontmost app has changed to a different bundle ID, a pending completion
    /// awaiting acceptance must be cancelled rather than pasted into the new app.
    public static func shouldCancelPending(activeAppIdentifier: String, currentFrontmost: String?) -> Bool {
        guard let currentFrontmost else { return true }
        // "unknown" is the sentinel used when no app could be resolved; a change
        // to a real app should cancel, and an indeterminate change should be
        // treated conservatively (cancel) to avoid a wrong-target paste.
        if activeAppIdentifier == "unknown" { return currentFrontmost != "unknown" }
        return currentFrontmost != activeAppIdentifier
    }
}

// MARK: - Clipboard value & snapshot (property-list / file-URL preserving)

/// A recursive, value-type property list. `NSPasteboard` stores several common
/// types (file URLs, file-promise filenames, rich text metadata) as property
/// lists rather than as raw `Data`. Capturing only `data(forType:)` loses those,
/// so this enum carries the structured representation so restore is faithful.
public enum ClipboardPropertyList: Equatable, Sendable {
    case string(String)
    case data(Data)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([ClipboardPropertyList])
    case dictionary([String: ClipboardPropertyList])

    /// Convert a Foundation property-list value (`String`, `Data`, `NSNumber`,
    /// `Array`, `Dictionary`, `Bool`) into this value type. Returns nil for
    /// values that are not valid property-list leaves.
    public init?(value: Any) {
        switch value {
        case let s as String: self = .string(s)
        case let d as Data: self = .data(d)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let n as NSNumber:
            // A Bool is a CFBoolean; other NSNumber values are numeric.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                let double = n.doubleValue
                if double == Double(n.intValue) { self = .int(n.intValue) } else { self = .double(double) }
            }
        case let a as [Any]:
            var out: [ClipboardPropertyList] = []
            for element in a {
                guard let converted = ClipboardPropertyList(value: element) else { return nil }
                out.append(converted)
            }
            self = .array(out)
        case let d as [String: Any]:
            var out: [String: ClipboardPropertyList] = [:]
            for (k, v) in d {
                guard let converted = ClipboardPropertyList(value: v) else { return nil }
                out[k] = converted
            }
            self = .dictionary(out)
        default:
            return nil
        }
    }

    /// Back to the Foundation value this came from.
    public var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .data(let d): return d
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .array(let a): return a.map { $0.anyValue }
        case .dictionary(let d): return d.mapValues { $0.anyValue }
        }
    }
}

/// One best-effort representation read from a pasteboard item for a single type.
/// Order matters on restore: prefer the representation that reconstructs the
/// type most faithfully without a forced lossy decode.
public enum ClipboardValue: Equatable, Sendable {
    case propertyList(ClipboardPropertyList)
    case string(String)
    case data(Data)

    /// Wrap a Foundation value read from the pasteboard into the value type.
    public init?(value: Any) {
        if let data = value as? Data {
            self = .data(data)
        } else if let string = value as? String {
            self = .string(string)
        } else if let plist = ClipboardPropertyList(value: value) {
            self = .propertyList(plist)
        } else {
            return nil
        }
    }

    /// The Foundation value to hand back to `NSPasteboardItem` on restore.
    public var anyValue: Any {
        switch self {
        case .propertyList(let p): return p.anyValue
        case .string(let s): return s
        case .data(let d): return d
        }
    }
}

/// A pure, value-type snapshot of the user's clipboard that survives the
/// suspension between paste and restore. Production code snapshots
/// `NSPasteboardItem`s; this value carries the data so restore is deterministic.
///
/// For each type it keeps the property-list, string, and data representations
/// that were readable, so file-URL / file-promise / rich-text types round-trip
/// instead of being dropped by a data-only read.
public struct ClipboardSnapshot: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let types: [String]
        public let dataByType: [String: Data]
        public let stringByType: [String: String]
        public let propertyListsByType: [String: ClipboardPropertyList]

        public init(
            types: [String],
            dataByType: [String: Data] = [:],
            stringByType: [String: String] = [:],
            propertyListsByType: [String: ClipboardPropertyList] = [:]
        ) {
            self.types = types
            self.dataByType = dataByType
            self.stringByType = stringByType
            self.propertyListsByType = propertyListsByType
        }

        /// The best representation to restore for `type`, or nil when none was read.
        /// Prefers string (plain text and file URLs), then property list (arrays,
        /// dictionaries, file-promise filenames), then raw data (RTF, images).
        public func representation(for type: String) -> ClipboardValue? {
            if let s = stringByType[type] { return .string(s) }
            if let p = propertyListsByType[type] { return .propertyList(p) }
            if let d = dataByType[type] { return .data(d) }
            return nil
        }
    }

    public var items: [Item]
    public var changeCount: Int

    public init(items: [Item], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }

    public static let empty = ClipboardSnapshot(items: [], changeCount: 0)
}

/// Pure policy for whether to restore the clipboard. Restores only when the
/// pasteboard was not modified by the user during the wait window.
public enum ClipboardRestorePolicy {
    /// Restore iff the change count is unchanged (the user did not copy anything
    /// while the paste command was landing).
    public static func shouldRestore(snapshotChangeCount: Int, currentChangeCount: Int) -> Bool {
        snapshotChangeCount == currentChangeCount
    }
}

/// Error surfaced when the insertion target changed between capture and paste.
public enum InsertionError: LocalizedError, Equatable {
    case targetChanged
    case permissionDenied
    case pasteboardWriteFailed
    case restoreFailed
    /// A direct AX write was attempted but its outcome was ambiguous; the
    /// completion is not retried via the pasteboard to avoid duplicating text.
    case directInsertFailed

    public var errorDescription: String? {
        switch self {
        case .targetChanged:
            return "The focused editor changed before the completion was inserted — nothing was pasted into the wrong field."
        case .permissionDenied:
            return "Cotype lacks Accessibility permission to paste into the focused app."
        case .pasteboardWriteFailed:
            return "Cotype could not place the completion on the pasteboard."
        case .restoreFailed:
            return "Cotype could not restore the clipboard after inserting."
        case .directInsertFailed:
            return "Cotype could not confirm a direct insertion — nothing further was inserted to avoid duplicating the text."
        }
    }
}
