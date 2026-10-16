import XCTest
@testable import CotypeCore

/// Boundary and legitimate-prefix tests for the shared output sanitizer and its
/// streaming guard. These lock the behavior required by the production-readiness
/// plan: no partial/full control-token leakage across arbitrary token
/// boundaries, no naive prompt-echo over-stripping, and structural drop.
final class OutputSanitizerTests: XCTestCase {

    // MARK: - Control-token leakage across arbitrary token boundaries

    func testSanitizerCutsAtFullTurnDelimiter() {
        let outcome = OutputSanitizer().process("hello<|turn>world", promptTail: "hello")
        XCTAssertEqual(outcome.text, "hello")
        XCTAssertFalse(outcome.isNoSuggestion)
    }

    func testSanitizerCutsAtReverseTurnDelimiter() {
        let outcome = OutputSanitizer().process("hello<turn|>world", promptTail: "hello")
        XCTAssertEqual(outcome.text, "hello")
    }

    func testSanitizerDropsIncompleteTrailingControlToken() {
        // The token never completed with '>', but the partial must not survive.
        let outcome = OutputSanitizer().process("hi<|tur", promptTail: "hi")
        XCTAssertEqual(outcome.text, "hi")
    }

    func testSanitizerPreservesLegitimateLessThan() {
        // A lone '<' in code must never be mistaken for a control precursor.
        let outcome = OutputSanitizer().process("if a < b then c", promptTail: "if a ")
        XCTAssertEqual(outcome.text, "if a < b then c")
    }

    func testSanitizerDropsStructuralChannelTag() {
        let outcome = OutputSanitizer().process("hello<|channel base>world", promptTail: "hello")
        XCTAssertEqual(outcome.text, "helloworld")
    }

    func testSanitizerDropsToolCallMarker() {
        let outcome = OutputSanitizer().process("let x = <|tool call>5", promptTail: "let x = ")
        XCTAssertEqual(outcome.text, "let x = 5")
    }

    func testSanitizerCutsAtStopSequenceDoubleNewline() {
        let outcome = OutputSanitizer().process("hello\n\nworld", promptTail: "hello")
        XCTAssertEqual(outcome.text, "hello")
    }

    // MARK: - Streaming guard: partial delimiters never leak

    func testStreamingGuardNeverLeaksControlTokenSplitAcrossTokens() {
        var streamGuard = StreamingOutputGuard()
        var emitted = ""
        // A model emitting '<|turn>' as eight separate tokens must never leak '<|turn'.
        let pieces = ["<", "|", "t", "u", "r", "n", ">"]
        for piece in pieces {
            emitted += streamGuard.append(piece)
        }
        XCTAssertEqual(emitted, "")
        XCTAssertTrue(streamGuard.isStopped)
    }

    func testStreamingGuardNeverLeaksReverseDelimiterSplitAcrossTokens() {
        var streamGuard = StreamingOutputGuard()
        var emitted = ""
        for piece in ["<", "t", "u", "r", "n", "|", ">"] {
            emitted += streamGuard.append(piece)
        }
        XCTAssertEqual(emitted, "")
        XCTAssertTrue(streamGuard.isStopped)
    }

    func testStreamingGuardNeverLeaksStopSequenceSplitAcrossTokens() {
        var streamGuard = StreamingOutputGuard()
        var emitted = ""
        for piece in ["\n", "\n"] {
            emitted += streamGuard.append(piece)
        }
        XCTAssertEqual(emitted, "")
        XCTAssertTrue(streamGuard.isStopped)
    }

    func testStreamingGuardFlushesLegitimatePrefix() {
        var streamGuard = StreamingOutputGuard()
        XCTAssertEqual(streamGuard.append("a + b"), "")
        XCTAssertEqual(streamGuard.finish(), "a + b")
    }

    func testStreamingGuardFlushesLegitimateTrailingNewline() {
        // A single trailing newline is legitimate content; only a full "\n\n"
        // is a stop. The guard must not strip the lone newline.
        var streamGuard = StreamingOutputGuard()
        XCTAssertEqual(streamGuard.append("hello\n"), "")
        XCTAssertEqual(streamGuard.finish(), "hello\n")
    }

    func testStreamingGuardFlushesLegitimateLessThanInCode() {
        var streamGuard = StreamingOutputGuard()
        XCTAssertEqual(streamGuard.append("if a < b"), "")
        XCTAssertEqual(streamGuard.finish(), "if a < b")
    }

    func testStreamingGuardKeepsForegroundThenFlushesOnStop() {
        var streamGuard = StreamingOutputGuard()
        // More than the boundary window so the guard can emit the safe front.
        let long = String(repeating: "x", count: 40) + "<|turn>"
        var emitted = ""
        for piece in [long] {
            emitted += streamGuard.append(piece)
        }
        // The safe front is emitted; the control token is never emitted.
        XCTAssertTrue(emitted.hasPrefix(String(repeating: "x", count: 40)))
        XCTAssertFalse(emitted.contains("<|turn>"))
        XCTAssertTrue(streamGuard.isStopped)
    }

    // MARK: - Prompt echo suppression (no naive over-stripping)

    func testSanitizerStripsFullPromptEcho() {
        let promptTail = "func add(a: Int, b: Int) -> Int {\n    return "
        let outcome = OutputSanitizer().process(promptTail + "a + b", promptTail: promptTail)
        XCTAssertEqual(outcome.text, "a + b")
    }

    func testSanitizerPreservesShortOverlapThatIsGenuineContinuation() {
        // "return " is only 7 chars; a short overlap must not be stripped.
        let outcome = OutputSanitizer().process("return value", promptTail: "let x = ")
        XCTAssertEqual(outcome.text, "return value")
    }

    func testSanitizerPreservesProseOverlap() {
        let outcome = OutputSanitizer().process(
            "brown fox jumps",
            promptTail: "The quick brown fox "
        )
        XCTAssertEqual(outcome.text, "brown fox jumps")
    }

    func testSanitizerStripsLongPromptEchoInProse() {
        let promptTail = "The quick brown fox jumps over the lazy "
        let outcome = OutputSanitizer().process(promptTail + "dog", promptTail: promptTail)
        XCTAssertEqual(outcome.text, "dog")
    }

    func testSanitizerDoesNotStripNonOverlappingContinuation() {
        let outcome = OutputSanitizer().process("question", promptTail: "To be or not to be, that is the ")
        XCTAssertEqual(outcome.text, "question")
    }

    // MARK: - No-suggestion detection

    // MARK: - Boundary-whitespace preservation (leading-space ghost / type-through)

    func testSanitizerPreservesLeadingSpaceForProseWordBoundary() {
        // The prompt tail does NOT end in whitespace, so a leading space is a
        // meaningful word boundary ("lazy" + " dog" -> "lazy dog", never
        // "lazydog"). It must be preserved for a leading-space ghost.
        let outcome = OutputSanitizer().process(" dog", promptTail: "The quick brown fox jumps over the lazy")
        XCTAssertEqual(outcome.text, " dog")
        XCTAssertFalse(outcome.isNoSuggestion)
    }

    func testSanitizerAvoidsDoubleSpaceWhenPromptEndsInSpace() {
        // The prompt tail already ends in a space, so a candidate leading space
        // would double it ("lazy  dog"). The redundant leading space is dropped.
        let outcome = OutputSanitizer().process(" dog", promptTail: "The quick brown fox jumps over the lazy ")
        XCTAssertEqual(outcome.text, "dog")
    }

    func testSanitizerPreservesCodeIndentationAfterPromptNewline() {
        // Prompt ends in a newline; the candidate starts with a newline + indent.
        // The double newline is dropped but the indentation is preserved.
        let outcome = OutputSanitizer().process("\n    print(1)", promptTail: "func foo() {\n")
        XCTAssertEqual(outcome.text, "    print(1)")
    }

    func testSanitizerPreservesLeadingNewlineAndIndentWhenPromptEndsNonWhitespace() {
        // Prompt ends with non-whitespace; the candidate line break + indent are
        // meaningful and fully preserved.
        let outcome = OutputSanitizer().process("\n    print(1)", promptTail: "func foo() {")
        XCTAssertEqual(outcome.text, "\n    print(1)")
    }

    func testSanitizerStreamingAndFinalLeadingWhitespaceConsistent() {
        // Simulate a streamed buffer; every presented candidate and the final
        // result must agree on leading whitespace (no flicker, no word merge).
        let promptTail = "The quick brown fox jumps over the lazy"
        var buffer = ""
        var presented: [String] = []
        for piece in [" dog", " runs"] {
            buffer += piece
            presented.append(OutputSanitizer().process(buffer, promptTail: promptTail).text)
        }
        let finalText = OutputSanitizer().process(buffer, promptTail: promptTail).text
        XCTAssertEqual(presented.last, finalText)
        XCTAssertEqual(finalText, " dog runs")
    }

    func testSanitizerMarksWhitespaceOnlyCandidateAsNoSuggestion() {
        // A candidate that is only whitespace has no meaningful content.
        let outcome = OutputSanitizer().process(" ", promptTail: "hello")
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerMarksNothingProducedAsNoSuggestion() {
        let outcome = OutputSanitizer().process("", promptTail: "hello")
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerMarksOnlyControlTokenAsNoSuggestion() {
        let outcome = OutputSanitizer().process("<|turn>model\n", promptTail: "hello")
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerMarksPureEchoAsNoSuggestionWhenLongEnough() {
        let promptTail = "To be or not to be, that is the "
        // The model re-emits the whole prompt tail and nothing else.
        let outcome = OutputSanitizer().process(promptTail, promptTail: promptTail)
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerMarksShortPureEchoAsNoSuggestion() {
        // A short pure echo (well under minEchoLength) is still a useless
        // reproduction of the prompt, not a continuation.
        let outcome = OutputSanitizer().process("The end.", promptTail: "The end.")
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerMarksWhitespacePaddedPureEchoAsNoSuggestion() {
        // A model that re-emits the prompt tail plus only a trailing newline (a
        // common Gemma artifact) must still be treated as a pure echo, not
        // preserved as a short overlap that leaks the prompt line.
        let outcome = OutputSanitizer().process("The end.\n", promptTail: "The end.")
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerMarksWhitespaceCollapsedMarkupEchoAsNoSuggestion() {
        let outcome = OutputSanitizer().process(
            "</body></html>",
            promptTail: "</body>\n</html>"
        )
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerStripsRepeatedTerminalCodeKeyword() {
        let outcome = OutputSanitizer().process(
            "throw FetchError.invalidID",
            promptTail: "guard id > 0 else {\n    throw "
        )
        XCTAssertEqual(outcome.text, "FetchError.invalidID")
    }

    func testSanitizerStripsRepeatedWordAtFieldBoundary() {
        let outcome = OutputSanitizer().process(
            "order number AX-2048",
            promptTail: "Regarding order "
        )
        XCTAssertEqual(outcome.text, "number AX-2048")
    }

    func testSanitizerStripsDuplicatedFillInSuffix() {
        let outcome = OutputSanitizer().process(
            "{total}\")",
            promptTail: "print(f\"Total: ",
            suffix: "\")\n"
        )
        XCTAssertEqual(outcome.text, "{total}")
    }

    func testSanitizerRejectsBoundaryRecomposition() {
        let outcome = OutputSanitizer().process(
            "width * height",
            promptTail: "func area() { return wid",
            suffix: "th * height\n}"
        )
        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.isNoSuggestion)
    }

    func testSanitizerDoesNotTreatGenuineContinuationAsWhitespaceEcho() {
        // A real continuation must never be mistaken for a whitespace-padded echo
        // just because it is short.
        let outcome = OutputSanitizer().process("question", promptTail: "To be or not to be, that is the ")
        XCTAssertEqual(outcome.text, "question")
        XCTAssertFalse(outcome.isNoSuggestion)
    }

    func testSanitizerReportsSuggestionForUsefulOutput() {
        let outcome = OutputSanitizer().process("a + b", promptTail: "func add(a: Int, b: Int) -> Int {\n    return ")
        XCTAssertEqual(outcome.text, "a + b")
        XCTAssertFalse(outcome.isNoSuggestion)
    }

    // MARK: - Forbidden-output detection (shared constants)

    func testContainsForbiddenDetectsControlTokensAndMarkers() {
        XCTAssertTrue(OutputSanitizer.containsForbidden("prefix<|turn>suffix"))
        XCTAssertTrue(OutputSanitizer.containsForbidden("prefix<|channel base>suffix"))
        XCTAssertTrue(OutputSanitizer.containsForbidden("prefix<|tool>suffix"))
        XCTAssertFalse(OutputSanitizer.containsForbidden("ordinary text"))
        XCTAssertFalse(OutputSanitizer.containsForbidden("if a < b then c"))
    }

    func testSanitizerConfigSharedDefaults() {
        XCTAssertTrue(OutputSanitizer.Config.gemmaControlTokens.contains("<|turn>"))
        XCTAssertTrue(OutputSanitizer.Config.gemmaStructuralPrefixes.contains("<|channel"))
        XCTAssertTrue(OutputSanitizer.Config.defaultStopSequences.contains("```"))
    }

    // MARK: - streaming boundary config is consistent with sanitizer

    func testStreamingGuardAndSanitizerAgreeOnBoundary() {
        let config = OutputSanitizer.Config.gemma
        var streamGuard = StreamingOutputGuard(config: config)
        // Feed a full control token as a single piece; both must cut/stop.
        _ = streamGuard.append("<|turn>")
        XCTAssertTrue(streamGuard.isStopped)
        let sanitized = OutputSanitizer(config: config).process("abc<|turn>def", promptTail: "abc")
        XCTAssertEqual(sanitized.text, "abc")
    }
}
