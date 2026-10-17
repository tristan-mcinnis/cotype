import XCTest
import CotypeCore
@testable import CotypeMenuApp

/// The Website Rules card's state: add normalisation, enable/disable, editable
/// per-site instructions and removal. The SwiftUI text field itself is a thin
/// binding over this model.
@MainActor
final class WebsiteRulesModelTests: XCTestCase {

    private func makeModel(_ name: String = "website-model") -> (WebsiteRulesModel, WebsiteRulesStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-\(name)-\(UUID().uuidString).json")
        let store = WebsiteRulesStore(fileURL: url)
        return (WebsiteRulesModel(store: store), store, url)
    }

    func testAddNormalisesAndEnablesTheSite() {
        let (model, _, url) = makeModel()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(model.add(host: "WWW.Example.com"))
        XCTAssertEqual(model.entries.map(\.host), ["example.com"])
        XCTAssertEqual(model.entries.first?.enabled, true)
        XCTAssertNil(model.entries.first?.instructions)
    }

    func testInvalidHostIsRefusedAndNothingIsStored() {
        let (model, _, url) = makeModel()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(model.add(host: "file:///tmp/notes.txt"))
        XCTAssertFalse(model.add(host: "not a host"))
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testInstructionsAreTrimmedSavedAndClearedWithoutTouchingEnabled() {
        let (model, _, url) = makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.add(host: "example.com"))
        model.setEnabled("example.com", false)

        model.setInstructions("example.com", "  Be concise. Use the customer's first name.  ")
        XCTAssertEqual(model.entries.first?.instructions, "Be concise. Use the customer's first name.")
        XCTAssertEqual(model.entries.first?.enabled, false, "editing instructions must not re-enable the site")

        model.setInstructions("example.com", "   \n  ")
        XCTAssertNil(model.entries.first?.instructions, "whitespace-only instructions are cleared")
        XCTAssertEqual(model.entries.first?.enabled, false)
    }

    func testDisablingPreservesInstructions() {
        let (model, _, url) = makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.add(host: "example.com"))
        model.setInstructions("example.com", "Short replies only.")

        model.setEnabled("example.com", false)
        XCTAssertEqual(model.entries.first?.instructions, "Short replies only.")
        XCTAssertEqual(model.entries.first?.enabled, false)

        model.setEnabled("example.com", true)
        XCTAssertEqual(model.entries.first?.instructions, "Short replies only.")
    }

    func testRemoveDeletesTheRule() {
        let (model, _, url) = makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.add(host: "example.com"))
        model.setInstructions("example.com", "Note")

        model.remove("example.com")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testEditsSurviveANewModelOnTheSameStore() {
        let (model, store, url) = makeModel("website-model-reload")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.add(host: "example.com"))
        model.setInstructions("example.com", "Persisted note")

        let reloaded = WebsiteRulesModel(store: store)
        XCTAssertEqual(reloaded.instructions(for: "example.com"), "Persisted note")
    }
}
