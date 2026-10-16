import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CotypeCore

/// Abstracts the clipboard snapshot/write/restore and the Cmd+V keypress so the
/// pasteboard-insertion focus guard can be exercised without touching the live
/// clipboard or posting synthetic keys. Concrete implementations are `@MainActor`
/// in practice (NSPasteboard/CGEvent are main-thread-only) because callers always
/// invoke them inside `MainActor.run`; the protocol requirements are kept
/// non-isolated so the existential conformance emits no actor-isolated witness.
public protocol ClipboardOperator {
    /// Snapshot the current clipboard into a pure, restorable value.
    func snapshot() -> ClipboardSnapshot
    /// Place `text` on the pasteboard for a paste; returns the resulting change
    /// count, or nil when the write failed.
    func writeForPaste(_ text: String) -> Int?
    /// Post a Cmd+V keypress so the focused app pastes the completion.
    func postPaste()
    /// Restore the snapshot. When `ignoreChangeCount` is false, restore only if
    /// the current change count equals `expectedChangeCount` (the user did not
    /// copy during the paste window). Returns true when a restore was attempted.
    @discardableResult
    func restore(_ snapshot: ClipboardSnapshot, expectedChangeCount: Int?, ignoreChangeCount: Bool) -> Bool
}

/// Production `ClipboardOperator` backed by `NSPasteboard.general` and a
/// synthesized Cmd+V. All methods must be invoked on the main actor (the
/// enclosing inserter does this).
public struct SystemClipboardOperator: ClipboardOperator {
    public init() {}

    public func snapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems else {
            return ClipboardSnapshot(items: [], changeCount: pasteboard.changeCount)
        }
        let snapshotItems = items.map { item -> ClipboardSnapshot.Item in
            let typeStrings = item.types.map { $0.rawValue }
            var dataByType: [String: Data] = [:]
            var stringByType: [String: String] = [:]
            var propertyListsByType: [String: ClipboardPropertyList] = [:]
            for type in item.types {
                let raw = type.rawValue
                if let data = item.data(forType: type) { dataByType[raw] = data }
                if let string = item.string(forType: type) { stringByType[raw] = string }
                if let plist = item.propertyList(forType: type), let converted = ClipboardPropertyList(value: plist) {
                    propertyListsByType[raw] = converted
                }
            }
            return ClipboardSnapshot.Item(
                types: typeStrings,
                dataByType: dataByType,
                stringByType: stringByType,
                propertyListsByType: propertyListsByType
            )
        }
        return ClipboardSnapshot(items: snapshotItems, changeCount: pasteboard.changeCount)
    }

    public func writeForPaste(_ text: String) -> Int? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return nil }
        return pasteboard.changeCount
    }

    public func postPaste() {
        // Tag the paste so Cotype's own taps ignore it. Untagged, the Cmd+V
        // looked like a user edit and cancelled the rest of the suggestion
        // (KeyType ADR-039 documents the same failure).
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = SyntheticEventTag.marker
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    @discardableResult
    public func restore(_ snapshot: ClipboardSnapshot, expectedChangeCount: Int?, ignoreChangeCount: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        if !ignoreChangeCount {
            guard let expectedChangeCount,
                  ClipboardRestorePolicy.shouldRestore(
                      snapshotChangeCount: expectedChangeCount,
                      currentChangeCount: pasteboard.changeCount
                  ) else {
                return false
            }
        }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }
        let restored = snapshot.items.compactMap { item -> NSPasteboardItem? in
            let pasteItem = NSPasteboardItem()
            var hasValue = false
            for type in item.types {
                guard let rep = item.representation(for: type) else { continue }
                switch rep {
                case .propertyList(let plist):
                    pasteItem.setPropertyList(plist.anyValue, forType: NSPasteboard.PasteboardType(type))
                case .string(let s):
                    pasteItem.setString(s, forType: NSPasteboard.PasteboardType(type))
                case .data(let d):
                    pasteItem.setData(d, forType: NSPasteboard.PasteboardType(type))
                }
                hasValue = true
            }
            return hasValue ? pasteItem : nil
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
        return true
    }
}

/// A `CompletionInserter` that commits text into the focused editor by swapping
/// the pasteboard and synthesizing a Cmd+V keypress.
///
/// `NSPasteboard` is main-thread only, so all pasteboard and `CGEvent` work is
/// hoisted onto the main actor while the wait between paste and restore stays
/// off-main. Safety guarantees:
///
/// - A permission preflight runs first so we never clobber the user's clipboard
///   on a keystroke that will not land.
/// - The insertion target is re-verified in the SAME synchronous main-actor turn
///   as the Cmd+V is posted. When a `FocusTarget` is threaded in, the exact
///   focused field (app + window + element + caret range) is re-checked — so a
///   same-app field/window switch or a caret move during clipboard preparation
///   is caught, not just an app switch. On a mismatch the clipboard is restored
///   and nothing is pasted.
/// - The clipboard is restored only when the change count is unchanged (the
///   user did not copy during the paste window).
public struct PasteboardInserter: CompletionInserter {

    public enum InsertError: LocalizedError, Equatable {
        case permissionDenied
        case pasteboardWriteFailed
        case targetChanged
        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Cotype lacks Accessibility permission to paste into the focused app."
            case .pasteboardWriteFailed:
                return "Cotype could not place the completion on the pasteboard."
            case .targetChanged:
                return "The focused editor changed before the completion was inserted — nothing was pasted."
            }
        }
    }

    /// How long to wait after pasting before restoring the user's clipboard.
    public var restoreDelayNanoseconds: UInt64

    /// Re-checks the (coarser) app insertion target right before the paste key is
    /// posted. Used as a backstop when no exact `FocusTarget` is available.
    private let verifier: InsertionTargetVerifier

    /// Re-checks the exact focused field (app/window/element/caret) immediately
    /// before the paste key is posted. Created lazily inside the main-actor
    /// closure so the `@MainActor` default does not need to exist in this
    /// non-isolated init.
    private let focusIdentityProvider: FocusIdentityProvider?

    /// The pasteboard + keypress operations (injectable for testing).
    private let clipboard: ClipboardOperator

    /// Preflight for event-posting permission. Injected so tests can drive the
    /// paste path without Accessibility trust.
    private let preflightPostEventAccess: () -> Bool

    public init(
        restoreDelayNanoseconds: UInt64 = 300_000_000,
        verifier: InsertionTargetVerifier = AXInsertionTargetVerifier(),
        focusIdentityProvider: FocusIdentityProvider? = nil,
        clipboard: ClipboardOperator = SystemClipboardOperator(),
        preflightPostEventAccess: @escaping () -> Bool = { CGPreflightPostEventAccess() }
    ) {
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
        self.verifier = verifier
        self.focusIdentityProvider = focusIdentityProvider
        self.clipboard = clipboard
        self.preflightPostEventAccess = preflightPostEventAccess
    }

    /// Plain `CompletionInserter` conformance: no target verification.
    public func insert(_ text: String) async throws {
        try await performInsert(text, appIdentifier: nil, focusTarget: nil)
    }

    public func insert(_ text: String, appIdentifier: String?) async throws {
        try await performInsert(text, appIdentifier: appIdentifier, focusTarget: nil)
    }

    /// Field-aware form: re-verifies the exact focused editor right before the
    /// paste is posted.
    public func insert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws {
        try await performInsert(text, appIdentifier: appIdentifier, focusTarget: focusTarget)
    }

    private func performInsert(_ text: String, appIdentifier: String?, focusTarget: FocusTarget?) async throws {
        // Synthetic keystrokes require event-posting (Accessibility) permission.
        // Check before touching the clipboard.
        guard preflightPostEventAccess() else {
            throw InsertError.permissionDenied
        }

        // Snapshot + write on the main thread.
        let preparation = await MainActor.run { () -> ClipboardPreparation? in
            let snapshot = clipboard.snapshot()
            guard let changeCount = clipboard.writeForPaste(text) else {
                // Restore what we cleared before failing.
                _ = clipboard.restore(snapshot, expectedChangeCount: snapshot.changeCount, ignoreChangeCount: true)
                return nil
            }
            return ClipboardPreparation(snapshot: snapshot, changeCount: changeCount)
        }
        guard let preparation else { throw InsertError.pasteboardWriteFailed }

        // Re-verify the insertion target and post Cmd+V in the SAME main-actor
        // turn so focus cannot change between the check and the paste. If the
        // target changed, restore the clipboard and cancel — never paste into
        // the wrong app or field.
        let posted = await MainActor.run { () -> Bool in
            let ok: Bool
            if let focusTarget {
                let provider = focusIdentityProvider ?? AXFocusIdentityProvider()
                ok = FocusIdentityPolicy.isValid(captured: focusTarget, current: provider.currentFocusTarget())
            } else if let appIdentifier {
                ok = verifier.verifyTarget(appIdentifier: appIdentifier)
            } else {
                ok = true
            }
            guard ok else {
                // Re-verify the target failed. Still post nothing, but restore
                // ONLY if the clipboard is unchanged since our write — a copy the
                // user made during the gap must not be clobbered.
                _ = clipboard.restore(preparation.snapshot, expectedChangeCount: preparation.changeCount, ignoreChangeCount: false)
                return false
            }
            clipboard.postPaste()
            return true
        }
        guard posted else { throw InsertError.targetChanged }

        // Give the paste a moment to land, then restore the clipboard on main.
        try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)

        await MainActor.run {
            _ = clipboard.restore(preparation.snapshot, expectedChangeCount: preparation.changeCount, ignoreChangeCount: false)
        }
    }
}

/// Carries the snapshot across the `Task.sleep` suspension point. Values are
/// only read/written on the main actor.
private struct ClipboardPreparation: @unchecked Sendable {
    let snapshot: ClipboardSnapshot
    let changeCount: Int
}
