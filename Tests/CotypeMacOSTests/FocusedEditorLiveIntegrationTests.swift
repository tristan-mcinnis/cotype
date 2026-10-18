import XCTest
import AppKit
import ApplicationServices
@testable import CotypeMacOS

/// Opt-in compatibility probe for a running app. It inspects AX capability
/// metadata only—never editor text—and proves that a container-focused app such
/// as ChatGPT resolves to one real, settable editor descendant.
@MainActor
final class FocusedEditorLiveIntegrationTests: XCTestCase {
    func testRunningAppResolvesToUsableEditor() throws {
        guard let rawPID = ProcessInfo.processInfo.environment["COTYPE_AX_LIVE_PID"],
              let pid = pid_t(rawPID)
        else {
            throw XCTSkip("set COTYPE_AX_LIVE_PID to a running app process")
        }

        let appElement = AXUIElementCreateApplication(pid)
        let root = attribute(appElement, kAXFocusedUIElementAttribute)
            ?? (attribute(appElement, kAXWindowsAttribute) as [AXUIElement]?)?.first
        let reported = try XCTUnwrap(root)
        let editor = try XCTUnwrap(AXFocusedEditorResolver.resolve(from: reported))

        let role: String? = attribute(editor, kAXRoleAttribute)
        XCTAssertTrue(role == kAXTextAreaRole || role == kAXTextFieldRole)
        XCTAssertNotNil(AXFocusedEditorResolver.usableFrame(of: editor))

        var settable = DarwinBoolean(false)
        XCTAssertEqual(
            AXUIElementIsAttributeSettable(editor, kAXSelectedTextAttribute as CFString, &settable),
            .success
        )
        XCTAssertTrue(settable.boolValue)

        if ProcessInfo.processInfo.environment["COTYPE_AX_EXPECT_WINDOW_CONTEXT"] == "1" {
            let context = AXActiveWindowContextCollector().context(
                from: reported,
                excluding: editor
            )
            XCTAssertFalse(context.isEmpty, "the active window should expose bounded surrounding text")
            XCTAssertLessThanOrEqual(context.count, 2_000)
        }
    }

    private func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Content-free geometry probe for the inline ghost.
    ///
    /// It prints the numbers the renderer will use — field and caret rects, the
    /// decoded font name and size, the line box, the baseline, and the measured
    /// text-column inset — plus the *names* of the font attributes the host put on
    /// its attributed string. It never prints editor text, never types, and never
    /// changes focus, so it can be pointed at a synthetic document while the user
    /// is working.
    ///
    /// Reproduce: focus the test document, then
    /// `COTYPE_AX_GHOST_PROBE_PID=<pid> swift test --filter testGhostGeometryProbe`.
    func testGhostGeometryProbe() throws {
        guard let rawPID = ProcessInfo.processInfo.environment["COTYPE_AX_GHOST_PROBE_PID"],
              let pid = pid_t(rawPID)
        else {
            throw XCTSkip("set COTYPE_AX_GHOST_PROBE_PID to a running editor's process")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the test process")
        }

        let appElement = AXUIElementCreateApplication(pid)
        let root = try XCTUnwrap(
            attribute(appElement, kAXFocusedUIElementAttribute)
                ?? (attribute(appElement, kAXWindowsAttribute) as [AXUIElement]?)?.first
        )
        let editor = try XCTUnwrap(AXFocusedEditorResolver.resolve(from: root))
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let geometry = try XCTUnwrap(
            AXCaretGeometryProvider().geometry(of: editor, bundleIdentifier: bundleIdentifier),
            "no usable caret geometry for the focused editor"
        )
        let metrics = geometry.metrics

        print("""
        GHOST_PROBE font=\(metrics.font.fontName) size=\(metrics.font.pointSize) \
        line=\(metrics.lineHeight) baseline=\(metrics.baselineOffset) \
        inset=\(geometry.textInset) caret=\(geometry.caretRect) field=\(geometry.fieldBounds) \
        fontAttributes=\(fontAttributeNames(of: editor)) lineAttributes=\(lineAttributeAnswers(of: editor))
        """)

        // Invariants the fix must hold for any editor that answers at all.
        XCTAssertTrue(
            AXCaretGeometryProvider.isUsableCaretRect(geometry.caretRect, inside: geometry.fieldBounds)
        )
        XCTAssertGreaterThan(metrics.lineHeight, 0)
        XCTAssertGreaterThanOrEqual(metrics.baselineOffset, 0)
        XCTAssertLessThan(metrics.baselineOffset, metrics.lineHeight)
        XCTAssertGreaterThanOrEqual(geometry.textInset, 0)
        XCTAssertLessThan(geometry.textInset, max(geometry.fieldBounds.width / 2, 1))
    }

    /// Names only, never values: which font attribute shape reached the decoder.
    private func fontAttributeNames(of editor: AXUIElement) -> [String] {
        guard let range: AXValue = attribute(editor, kAXSelectedTextRangeAttribute),
              AXValueGetType(range) == .cfRange
        else { return [] }
        var caret = CFRange()
        guard AXValueGetValue(range, .cfRange, &caret) else { return [] }
        var probe = caret.location > 0
            ? CFRange(location: caret.location - 1, length: 1)
            : CFRange(location: 0, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &probe) else { return [] }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            editor,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        guard error == .success,
              let attributed = value as? NSAttributedString,
              attributed.length > 0
        else { return [] }
        return attributed.attributes(at: 0, effectiveRange: nil)
            .keys
            .map(\.rawValue)
            .sorted()
    }

    /// Which optional line-geometry attributes answer for this editor. The ghost's
    /// text-column inset needs both; a host that answers neither keeps the field
    /// edge. Reported as yes/no only.
    private func lineAttributeAnswers(of editor: AXUIElement) -> String {
        guard let range: AXValue = attribute(editor, kAXSelectedTextRangeAttribute),
              AXValueGetType(range) == .cfRange
        else { return "no-selection-range" }
        var caret = CFRange()
        guard AXValueGetValue(range, .cfRange, &caret) else { return "no-selection-range" }
        let index = max(caret.location - 1, 0)

        var lineValue: CFTypeRef?
        let lineAnswered = AXUIElementCopyParameterizedAttributeValue(
            editor,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: index),
            &lineValue
        ) == .success && lineValue != nil
        guard lineAnswered, let lineNumber = (lineValue as? NSNumber)?.intValue else {
            return "lineForIndex=no"
        }
        var rangeValue: CFTypeRef?
        let rangeAnswered = AXUIElementCopyParameterizedAttributeValue(
            editor,
            kAXRangeForLineParameterizedAttribute as CFString,
            NSNumber(value: lineNumber),
            &rangeValue
        ) == .success && rangeValue != nil
        return "lineForIndex=yes rangeForLine=\(rangeAnswered ? "yes" : "no")"
    }
}
