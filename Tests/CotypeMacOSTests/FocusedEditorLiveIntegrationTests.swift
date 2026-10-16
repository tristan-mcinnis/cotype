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
}
