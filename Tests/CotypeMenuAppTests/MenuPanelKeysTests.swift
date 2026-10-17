import AppKit
import XCTest
@testable import CotypeMenuApp
import HouseUIKit

/// The keys the shared panel controller routes, driven through the real
/// controller without opening a window.
@MainActor
final class MenuPanelKeysTests: XCTestCase {

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) throws -> PanelKeyPress {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code
        ))
        return PanelKeyPress(event)
    }

    private func makeController(ran: @escaping (String) -> Void = { _ in }) -> MenuBarPanelController {
        let controller = MenuBarPanelController()
        controller.model.actions = [
            PanelAction(id: "a", glyph: "circle", title: "A") { ran("a") },
            PanelAction(id: "b", glyph: "circle", title: "B") { ran("b") },
        ]
        return controller
    }

    func testEscapeClosesThroughTheModel() throws {
        let controller = makeController()
        var closed = 0
        controller.model.onClose = { closed += 1 }
        XCTAssertTrue(controller.handle(try key(53)))
        XCTAssertEqual(closed, 1)
    }

    func testArrowsMoveTheSelectionAndWrap() throws {
        let controller = makeController()
        XCTAssertTrue(controller.handle(try key(125)))
        XCTAssertEqual(controller.model.selection, 1)
        XCTAssertTrue(controller.handle(try key(126)))
        XCTAssertTrue(controller.handle(try key(126)))
        XCTAssertEqual(controller.model.selection, controller.model.selectableActions.count - 1)
    }

    func testReturnAndEnterRunTheSelectedRow() throws {
        var ran: [String] = []
        let controller = makeController { ran.append($0) }
        controller.model.selection = 1
        XCTAssertTrue(controller.handle(try key(36)))
        XCTAssertTrue(controller.handle(try key(76)))
        XCTAssertEqual(ran, ["b", "b"])
    }

    func testOtherKeysReachTheFocusedView() throws {
        let controller = makeController()
        XCTAssertFalse(controller.handle(try key(0, "a")))
        XCTAssertFalse(controller.handle(try key(0, "a", flags: .command)))
    }

    func testClosingBeforeTheFirstShowIsHarmless() {
        let controller = makeController()
        controller.close()
        XCTAssertFalse(controller.isVisible)
    }
}
