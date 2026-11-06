import XCTest
@testable import CotypeCore

final class WritingMemoryTests: XCTestCase {

    private func written(_ text: String, app: String = "chat") -> PersonalizationSample {
        PersonalizationSample(prefix: text, completion: "", outcome: .written, appIdentifier: app)
    }

    private func store() -> PersonalizationStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return PersonalizationStore(
            fileURL: dir.appendingPathComponent("p.json"),
            configURL: dir.appendingPathComponent("c.json"),
            metricsURL: dir.appendingPathComponent("m.json")
        )
    }

    func testPiecesAreFinishedSentencesAndTheTypedOneWithoutItsLastWord() {
        XCTAssertEqual(
            WritingMemory.pieces(of: "ok that all looks fine to me. Too short. so i think we should wa"),
            ["ok that all looks fine to me.", "so i think we should"]
        )
    }

    func testPiecesSkipCodeAddressesLinksAndLongNumbers() {
        XCTAssertEqual(WritingMemory.pieces(of: "func main() {\n  let total = items.count;\n}\n"), [])
        for line in ["please write to anna at anna@mail.example today\n",
                     "the link is https://mail.example/a for you\n",
                     "my card number is 41111111 ok then\n"] {
            XCTAssertEqual(WritingMemory.pieces(of: line), [], line)
        }
    }

    func testAGrowingSentenceLeavesOneRecord() {
        let store = store()
        store.recordWriting(fromPrefix: "so i think we should go ", appIdentifier: "chat")
        store.recordWriting(fromPrefix: "so i think we should go and check it ", appIdentifier: "chat")
        store.recordWriting(fromPrefix: "so i think we should go ", appIdentifier: "chat")
        XCTAssertEqual(store.samples().map(\.prefix), ["so i think we should go and check it"])
    }

    func testMeetingAppsAreNeitherKeptNorShown() {
        let store = store()
        store.recordWriting(fromPrefix: "so i think we should go ", appIdentifier: "us.zoom.xos")
        store.recordWriting(fromPrefix: "so i think we should go ", appIdentifier: "com.tristan.rti.personal")
        XCTAssertEqual(store.count, 0)
        let earlier = written("what they said on the call today", app: "us.zoom.xos")
        XCTAssertEqual(WritingMemory.examples(from: [earlier], prefix: "hello there friend", appIdentifier: "mail"), [])
    }

    func testWritingIsNotKeptWhenRetentionIsOff() {
        let store = store()
        store.setRetentionPolicy(.off)
        store.recordWriting(fromPrefix: "so i think we should go ", appIdentifier: "chat")
        XCTAssertEqual(store.count, 0)
    }

    func testWritingCountsTowardNoUsageMetric() {
        let store = store()
        store.recordWriting(fromPrefix: "so i think we should go ", appIdentifier: "chat")
        XCTAssertTrue(store.metricCounts.isEmpty)
    }

    func testOldestWritingIsDroppedPastTheCap() {
        let store = store()
        for index in 0...WritingMemory.maxKept {
            store.recordWriting(fromPrefix: "number \(index) is the one we want. ", appIdentifier: "chat")
        }
        let kept = store.samples().map(\.prefix)
        XCTAssertEqual(kept.count, WritingMemory.maxKept)
        XCTAssertFalse(kept.contains("number 0 is the one we want."))
    }

    func testTheCapHoldsWhenOneReadAddsSeveralSentences() {
        let store = store()
        for field in 0..<(WritingMemory.maxKept / 2) {
            let text = (0..<5).map { "Field \(field) has sentence number \($0) in it." }.joined(separator: " ") + " "
            store.recordWriting(fromPrefix: text, appIdentifier: "chat")
        }
        let kept = store.samples().map(\.prefix)
        XCTAssertEqual(kept.count, WritingMemory.maxKept)
        XCTAssertTrue(kept.contains("Field \(WritingMemory.maxKept / 2 - 1) has sentence number 4 in it."))
        XCTAssertFalse(kept.contains("Field 0 has sentence number 0 in it."))
    }

    func testExamplesPreferSharedWordsThenThisAppThenNewest() {
        let samples = [
            written("the newest thing on my mind today"),
            written("this one is from the mail app today", app: "mail"),
            written("older note about the screener numbers"),
        ]
        XCTAssertEqual(
            WritingMemory.examples(from: samples, prefix: "can you check the screener ", appIdentifier: "mail"),
            ["older note about the screener numbers", "this one is from the mail app today", "the newest thing on my mind today"]
        )
    }

    func testExamplesSkipWhatIsAlreadyInTheTextAndAnotherScript() {
        let samples = [written("so i think we should"), written("我们下周一可以开个会讨论一下")]
        XCTAssertEqual(WritingMemory.examples(from: samples, prefix: "so i think we should go", appIdentifier: "chat"), [])
    }

    func testExamplesIgnoreDismissedCompletionsAndCodeLikeText() {
        let dismissed = PersonalizationSample(prefix: "a whole long line of text here", completion: " yes", outcome: .dismissed, appIdentifier: "chat")
        XCTAssertEqual(WritingMemory.examples(from: [dismissed], prefix: "hello there friend", appIdentifier: "chat"), [])
        XCTAssertEqual(WritingMemory.examples(from: [written("a whole long line of text")], prefix: "func main() {\n  let x = ", appIdentifier: "chat"), [])
    }

    func testAcceptedCompletionsCountAsWriting() {
        let accepted = PersonalizationSample(prefix: "first line\nthanks for the", completion: " quick reply today", outcome: .accepted, appIdentifier: "chat")
        XCTAssertEqual(
            WritingMemory.examples(from: [accepted], prefix: "hello there friend", appIdentifier: "chat"),
            ["thanks for the quick reply today"]
        )
    }

    func testLongExamplesKeepTheirEndOnAWordBoundary() {
        let long = String(repeating: "word ", count: 30) + "the end"
        let example = WritingMemory.examples(from: [written(long)], prefix: "hello there friend", appIdentifier: "chat")[0]
        XCTAssertLessThanOrEqual(example.count, 90)
        XCTAssertTrue(example.hasPrefix("word "))
        XCTAssertTrue(example.hasSuffix("the end"))
    }
}
