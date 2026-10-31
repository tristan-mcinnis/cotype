import XCTest
import CotypeCore
@testable import CotypeMacOS

final class GenerationPromptTests: XCTestCase {

    private func instructionPrompt(
        stored: String? = nil,
        website: String? = nil,
        app: String? = nil,
        length: SuggestionLength = .short,
        facts: String = ""
    ) -> TemplatePromptBuilder {
        GenerationPrompt.make(
            length: length,
            style: .instruction,
            storedPrompt: stored,
            websitePrompt: website,
            appPrompt: app,
            personalFacts: facts
        )
    }

    func testWebsiteInstructionWinsOverAppAndGlobal() {
        let system = instructionPrompt(stored: "Global note", website: "Site note", app: "App note").systemTemplate
        XCTAssertTrue(system.contains("Writing style: Site note"))
        XCTAssertFalse(system.contains("App note"))
        XCTAssertFalse(system.contains("Global note"))
    }

    func testAppInstructionWinsOverGlobal() {
        let system = instructionPrompt(stored: "Global note", app: "App note").systemTemplate
        XCTAssertTrue(system.contains("Writing style: App note"))
        XCTAssertFalse(system.contains("Global note"))
    }

    func testBlankOverrideDoesNotShadowParent() {
        let system = instructionPrompt(stored: "Global note", website: "  \n", app: "").systemTemplate
        XCTAssertTrue(system.contains("Writing style: Global note"))
    }

    func testShippedDefaultPromptIsNotACustomInstruction() {
        let withDefault = instructionPrompt(stored: AutocompletePrompt.defaultSystem).systemTemplate
        XCTAssertEqual(withDefault, instructionPrompt(stored: nil).systemTemplate)
        XCTAssertFalse(withDefault.contains("Writing style:"))
    }

    func testInstructionLaneCarriesLengthDirective() {
        XCTAssertTrue(instructionPrompt(length: .medium).systemTemplate.contains(SuggestionLength.medium.chatDirective))
    }

    func testContinuationLaneIgnoresInstructionAndAppliesLengthAndFacts() {
        let builder = GenerationPrompt.make(
            length: .long,
            style: .continuation,
            storedPrompt: "Global note",
            websitePrompt: "Site note",
            appPrompt: nil,
            personalFacts: "Name: Ada"
        )
        XCTAssertEqual(builder.style, .continuation)
        XCTAssertEqual(builder.personalFacts, "Name: Ada")
        XCTAssertFalse(builder.systemTemplate.contains("Site note"))
        XCTAssertTrue(builder.systemTemplate.contains(SuggestionLength.long.promptPhrase))
        XCTAssertTrue(builder.systemTemplate.contains("- Name: Ada"))
    }

    func testFirstNonEmptyTrimsAndSkipsBlanks() {
        XCTAssertEqual(GenerationPrompt.firstNonEmpty([nil, " ", "  keep me \n", "later"]), "keep me")
        XCTAssertEqual(GenerationPrompt.firstNonEmpty([nil, ""]), "")
    }
}
