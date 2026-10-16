import AppKit
import ApplicationServices
import CotypeCore

/// Experimental caret for terminals (Ghostty), which expose their visible
/// screen as one AX text value but always report the selection at 0 and have
/// no `AXBoundsForRange`. No reference app supports terminals for this reason.
///
/// Workaround: Cotype already sees every key the user types (listen-only tap).
/// The last few typed characters are found on the screen text; the caret is
/// taken to sit right after their last occurrence. The screen is a monospace
/// grid, so the caret's position comes from its row and column times the cell
/// size (the field's height over the number of rows, its width over the
/// widest row). A guess, not ground truth: it fails closed when the typed
/// text is too short or not on screen.
@MainActor
public enum TerminalCaret {
    /// Keys typed into the terminal since the last edit, focus change, or
    /// Return. Kept in memory only, capped, never logged.
    private(set) static var typed = ""

    /// At least this many typed characters are needed before a match is
    /// trusted; shorter strings match too many places on screen.
    static let minimumMatch = 3
    static let maxTyped = 80

    public static func noteTyped(_ text: String) {
        typed += text
        if typed.count > maxTyped { typed = String(typed.suffix(maxTyped)) }
    }

    /// Backspace, Return, paste, arrows, focus changes: the buffer no longer
    /// describes the text before the caret.
    public static func reset() {
        typed = ""
    }

    // MARK: - Pure locating

    /// UTF-16 offset just after the last on-screen occurrence of the typed
    /// tail, or nil when it cannot be located.
    static func caretOffset(in screen: String, typed: String) -> Int? {
        let needle = String(typed.suffix(40))
        guard needle.count >= minimumMatch else { return nil }
        let ns = screen as NSString
        let found = ns.range(of: needle, options: .backwards)
        if found.location != NSNotFound { return found.location + found.length }
        // A terminal can soft-wrap or re-render the start of what was typed;
        // fall back to the last `minimumMatch * 2` characters.
        let shorter = String(needle.suffix(minimumMatch * 2))
        guard shorter.count >= minimumMatch, shorter != needle else { return nil }
        let retry = ns.range(of: shorter, options: .backwards)
        return retry.location == NSNotFound ? nil : retry.location + retry.length
    }

    /// Row and column (in characters) of a UTF-16 offset on a newline-separated
    /// screen.
    static func gridPosition(of offset: Int, in screen: String) -> (row: Int, column: Int) {
        let ns = screen as NSString
        let before = ns.substring(to: min(offset, ns.length))
        let rows = before.components(separatedBy: "\n")
        return (rows.count - 1, rows.last?.count ?? 0)
    }

    /// The caret rect in AX (top-left origin) coordinates.
    static func caretRect(row: Int, column: Int, field: CGRect, screen: String) -> CGRect? {
        let lines = screen.components(separatedBy: "\n")
        guard !lines.isEmpty, field.height > 0, field.width > 0 else { return nil }
        let rowHeight = field.height / CGFloat(lines.count)
        let widest = lines.map(\.count).max() ?? 0
        // A full-width row (a border, a prompt line) gives the real cell
        // width; otherwise assume a typical monospace aspect.
        let cellWidth = widest >= 40 ? field.width / CGFloat(widest) : rowHeight * 0.47
        let rect = CGRect(
            x: field.minX + CGFloat(column) * cellWidth,
            y: field.minY + CGFloat(row) * rowHeight,
            width: 1,
            height: rowHeight
        )
        return field.insetBy(dx: -1, dy: -1).contains(rect.origin) ? rect : nil
    }

    // MARK: - Live

    /// Caret offset for the live terminal element's text.
    static func caretOffset(forScreen screen: String) -> Int? {
        caretOffset(in: screen, typed: typed)
    }

    /// Inline geometry for the focused terminal element, or nil.
    static func geometry(element: AXUIElement, field: CGRect) -> CaretGeometry? {
        guard let screen = stringValue(element),
              let offset = caretOffset(forScreen: screen) else {
            CotypeLog.geometry.info("terminal: typed text not found on screen")
            return nil
        }
        let position = gridPosition(of: offset, in: screen)
        guard let caret = caretRect(row: position.row, column: position.column, field: field, screen: screen) else {
            return nil
        }
        let font = NSFont.monospacedSystemFont(ofSize: max(9, caret.height / 1.25), weight: .regular)
        CotypeLog.geometry.debug("caret via terminalGrid")
        return CaretGeometry(caretRect: caret, fieldBounds: field, metrics: GhostTextMetrics(font: font))
    }

    private static func stringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// Types text into the focused app as tagged Unicode key events (TabType's
/// default insertion). Used for terminals, which accept neither AX insertion
/// nor a clean paste. Tagged so Cotype's own taps ignore the events.
enum KeystrokeTyper {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = SyntheticEventTag.marker
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            index += chunk.count
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }
}
