import AppKit
import XCTest
import CotypeCore
@testable import CotypeMacOS

// MARK: - End-to-end: typed text -> suggestion -> ghost -> accept -> inserted text
//
// These tests drive the real `CompletionController` the menu app runs, with the
// production engine stack (`LocalModelsCompletionEngine` -> registry lookup ->
// `OpenAICompatibleEngine`) talking to a fake llama-server over URLProtocol.
// The editor is an in-process `NSTextView`: context is read from it and the
// accepted text is inserted into it, so each case checks the final document,
// not an intermediate string. Nothing here touches the real screen, the real
// focused app, or a real model.
//
// The fake server behaves like llama-server: it answers `/v1/models` on the
// control plane, and on `/v1/completions` it streams the scripted model output
// as SSE tokens and stops at the request's stop sequences. A case's `model`
// string is what the model writes after the prompt text it receives.

@MainActor
final class EndToEndPipelineTests: XCTestCase {

    // MARK: Case table

    struct Case {
        var name: String
        /// Document text before the caret.
        var before: String
        /// Document text after the caret.
        var after: String = ""
        var style: PromptStyle = .continuation
        var length: SuggestionLength = .medium
        /// What the model generates (continuation of the prompt text, or the
        /// chat answer for the instruction style).
        var model: String
        /// The ghost the user should see; nil means no suggestion.
        var ghost: String?
        /// The document after accepting the whole suggestion (or unchanged).
        var document: String
        /// Whether the engine must be asked at all.
        var expectsRequest = true
    }

    static let cases: [Case] = [
        // Word boundaries: "by" + "the end" must never become "bythe end".
        Case(name: "caret after word, model adds the space", before: "Let me get back to you by",
             model: " the end of the day", ghost: " the end of the day",
             document: "Let me get back to you by the end of the day"),
        Case(name: "caret after space is token-healed", before: "Let me get back to you by ",
             model: " the end of the day", ghost: "the end of the day",
             document: "Let me get back to you by the end of the day"),
        Case(name: "instruction model drops the space", before: "Let me get back to you by",
             style: .instruction, model: "the end", ghost: " the end",
             document: "Let me get back to you by the end"),
        Case(name: "instruction model after space", before: "Let me get back to you by ",
             style: .instruction, model: " the end", ghost: "the end",
             document: "Let me get back to you by the end"),
        // Mid-word.
        Case(name: "mid-word continuation", before: "Do you have any questi",
             model: "ons about the plan?", ghost: "ons about the plan?",
             document: "Do you have any questions about the plan?"),
        Case(name: "instruction model restates the partial word", before: "Do you have any questi",
             style: .instruction, model: "questions for me", ghost: "ons for me",
             document: "Do you have any questions for me"),
        Case(name: "instruction model joins a real word", before: "Thanks for the quick turnar",
             style: .instruction, model: "ound on the review", ghost: "ound on the review",
             document: "Thanks for the quick turnaround on the review"),
        Case(name: "caret inside a word with text after it abstains", before: "return wid", after: "th * height",
             model: "th", ghost: nil, document: "return width * height", expectsRequest: false),
        // Punctuation and code.
        Case(name: "member access gets no invented space", before: "return res.",
             model: "json();", ghost: "json();", document: "return res.json();"),
        Case(name: "sentence end: model ends the line, no suggestion", before: "The end.",
             model: "\nNext paragraph", ghost: nil, document: "The end."),
        Case(name: "never closes more than was opened", before: "[Cotype](https://github.com/",
             model: "tristan/cotype)),", ghost: "tristan/cotype)",
             document: "[Cotype](https://github.com/tristan/cotype)"),
        Case(name: "does not duplicate text after the caret", before: "print(\"hello, ", after: "\")",
             model: " world\")", ghost: "world",
             document: "print(\"hello, world\")"),
        // Length and lines.
        Case(name: "short length caps at three words", before: "I think we should",
             length: .short, model: " move the meeting to Friday", ghost: " move the meeting",
             document: "I think we should move the meeting"),
        Case(name: "suggestion stops at the line end", before: "Best,",
             model: " Jane\nSent from my phone", ghost: " Jane",
             document: "Best, Jane"),
        Case(name: "after a line break", before: "Hi Sam,\n",
             model: "Thanks for the update.", ghost: "Thanks for the update.",
             document: "Hi Sam,\nThanks for the update."),
        Case(name: "two trailing spaces stay in the prompt", before: "Hello  ",
             model: "world", ghost: "world", document: "Hello  world"),
        // Safety and cleanup.
        Case(name: "control token is cut", before: "I will send it",
             model: " soon<|turn>model\nsure", ghost: " soon",
             document: "I will send it soon"),
        Case(name: "repeated boundary word is dropped", before: "Regarding order ",
             model: " order number AX-2048", ghost: "number AX-2048",
             document: "Regarding order number AX-2048"),
        Case(name: "empty model output shows nothing", before: "Okay",
             model: "", ghost: nil, document: "Okay"),
        Case(name: "CJK gets no synthesized space", before: "我们下周一可以",
             model: "开个会讨论一下吗？", ghost: "开个会讨论一下吗？",
             document: "我们下周一可以开个会讨论一下吗？"),
        Case(name: "email address from context", before: "You can reach me at ",
             model: " jane@example.com", ghost: "jane@example.com",
             document: "You can reach me at jane@example.com"),
        Case(name: "number continuation", before: "The meeting is at 3",
             model: "pm tomorrow", ghost: "pm tomorrow",
             document: "The meeting is at 3pm tomorrow"),
    ]

    func testEveryCaseInsertsTheRightText() async throws {
        XCTAssertGreaterThanOrEqual(Self.cases.count, 20)
        var failures: [String] = []
        for testCase in Self.cases {
            let outcome = await run(testCase)
            if let problem = outcome { failures.append("\(testCase.name): \(problem)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        print("E2E: \(Self.cases.count - failures.count)/\(Self.cases.count) cases passed")
    }

    /// Run one case; returns nil on success or a description of what differed.
    private func run(_ testCase: Case) async -> String? {
        let rig = Rig(before: testCase.before, after: testCase.after, style: testCase.style, length: testCase.length)
        FakeLlamaServer.reset(model: testCase.model)

        // The keystroke that produced the text arms the typing debounce.
        rig.controller.noteTyped(String(testCase.before.last ?? " "))

        if let ghost = testCase.ghost {
            guard await waitUntil({ rig.controller.phase == .awaitingAccept }) else {
                return "no suggestion appeared (lastError: \(rig.controller.lastError ?? "nil"))"
            }
            if rig.renderer.ghost != ghost {
                return "ghost \(String(reflecting: rig.renderer.ghost)) != \(String(reflecting: ghost))"
            }
            rig.controller.accept()
            guard await waitUntil({ rig.editor.string != testCase.before + testCase.after }) else {
                return "accept inserted nothing"
            }
        } else {
            // Give a would-be generation ample time, then require silence.
            _ = await waitUntil({ FakeLlamaServer.completionRequests > 0 }, timeout: 0.6)
            try? await Task.sleep(nanoseconds: 150_000_000)
            if rig.controller.phase == .awaitingAccept {
                return "unexpected suggestion \(String(reflecting: rig.renderer.ghost))"
            }
        }
        if rig.editor.string != testCase.document {
            return "document \(String(reflecting: rig.editor.string)) != \(String(reflecting: testCase.document))"
        }
        if testCase.expectsRequest != (FakeLlamaServer.completionRequests > 0) {
            return "engine requests: \(FakeLlamaServer.completionRequests), expected \(testCase.expectsRequest ? ">0" : "0")"
        }
        if testCase.style == .continuation, testCase.expectsRequest,
           let body = FakeLlamaServer.lastCompletionBody {
            // Token healing: a prompt never ends on the caret's single space,
            // and then the grammar forces the model to write it.
            let prompt = body["prompt"] as? String ?? ""
            let healed = testCase.before.hasSuffix(" ") && !testCase.before.hasSuffix("  ")
            if healed != (body["grammar"] != nil) { return "grammar presence wrong" }
            if healed && prompt.hasSuffix(" ") { return "prompt still ends in the caret space" }
            if (body["stop"] as? [String]) != ["\n"] { return "stop sequences \(String(describing: body["stop"]))" }
        }
        return nil
    }

    // MARK: Stepping, type-through, dismissal, focus, cold model

    func testTabStepsWordByWordThenAcceptsTheRest() async {
        let rig = Rig(before: "See you")
        FakeLlamaServer.reset(model: " at the office tomorrow")
        rig.controller.noteTyped("u")
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(rig.renderer.ghost, " at the office tomorrow")

        rig.controller.acceptNextWord()
        _ = await waitUntil { rig.editor.string == "See you at " }
        XCTAssertEqual(rig.editor.string, "See you at ")
        XCTAssertEqual(rig.renderer.ghost, "the office tomorrow")

        rig.controller.acceptNextWord()
        _ = await waitUntil { rig.editor.string == "See you at the " }
        XCTAssertEqual(rig.renderer.ghost, "office tomorrow")

        rig.controller.accept()
        _ = await waitUntil { rig.editor.string == "See you at the office tomorrow" }
        XCTAssertEqual(rig.editor.string, "See you at the office tomorrow")
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    func testTypingThroughTheGhostKeepsTheRest() async {
        let rig = Rig(before: "Let me get back to you by")
        FakeLlamaServer.reset(model: " the end of the day")
        rig.controller.noteTyped("y")
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)

        // The user types " th" themselves; the host applies the keys first.
        rig.editor.insertText(" th", replacementRange: rig.editor.selectedRange())
        rig.controller.noteTyped(" th")
        XCTAssertEqual(rig.renderer.ghost, "e end of the day")

        rig.controller.accept()
        _ = await waitUntil { rig.editor.string == "Let me get back to you by the end of the day" }
        XCTAssertEqual(rig.editor.string, "Let me get back to you by the end of the day")
    }

    /// Chromium/Electron apply a key to their AX tree after Cotype's typing
    /// observer runs, so an AX read at type-through time can return the
    /// pre-key caret. The captured target must advance by the typed text, not
    /// copy that stale read, or the accept that follows fails its focus check.
    func testTypeThroughInALaggingHostStillAccepts() async {
        let before = "Let me get back to you by"
        let rig = Rig(before: before)
        func focus(at location: Int) -> FocusTarget {
            FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 2,
                        selection: .range(.init(location: location, length: 0)))
        }
        let caret = (before as NSString).length
        rig.focus.current = focus(at: caret)
        FakeLlamaServer.reset(model: " the end of the day")
        rig.controller.noteTyped("y")
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)

        // The host takes the keys, but its AX caret has not caught up yet.
        rig.editor.insertText(" th", replacementRange: rig.editor.selectedRange())
        rig.controller.noteTyped(" th")
        XCTAssertEqual(rig.renderer.ghost, "e end of the day")

        // AX catches up before the user accepts.
        rig.focus.current = focus(at: caret + 3)
        rig.controller.accept()
        _ = await waitUntil { rig.editor.string == "Let me get back to you by the end of the day" }
        XCTAssertEqual(rig.editor.string, "Let me get back to you by the end of the day")
    }

    /// A host that moved the caret somewhere other than past the typed text
    /// fails closed: nothing is inserted.
    func testTypeThroughThenUnexpectedCaretInsertsNothing() async {
        let before = "Let me get back to you by"
        let rig = Rig(before: before)
        func focus(at location: Int) -> FocusTarget {
            FocusTarget(appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 2,
                        selection: .range(.init(location: location, length: 0)))
        }
        let caret = (before as NSString).length
        rig.focus.current = focus(at: caret)
        FakeLlamaServer.reset(model: " the end of the day")
        rig.controller.noteTyped("y")
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)

        rig.editor.insertText(" th", replacementRange: rig.editor.selectedRange())
        rig.controller.noteTyped(" th")
        rig.focus.current = focus(at: 3)
        rig.controller.accept()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.editor.string, "Let me get back to you by th")
    }

    func testMismatchedTypingDismissesWithoutInserting() async {
        let rig = Rig(before: "Let me get back to you by", autoSuggest: false)
        FakeLlamaServer.reset(model: " the end of the day")
        XCTAssertTrue(rig.controller.trigger())
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        rig.editor.insertText(" x", replacementRange: rig.editor.selectedRange())
        rig.controller.noteTyped(" x")
        XCTAssertNotEqual(rig.controller.phase, .awaitingAccept)
        XCTAssertNil(rig.renderer.ghost)
        XCTAssertEqual(rig.editor.string, "Let me get back to you by x")
    }

    func testEscapeDismissesWithoutInserting() async {
        let rig = Rig(before: "Let me get back to you by")
        FakeLlamaServer.reset(model: " the end of the day")
        rig.controller.noteTyped("y")
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        rig.controller.cancel(recordingRejection: true)
        XCTAssertNil(rig.renderer.ghost)
        rig.controller.accept()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.editor.string, "Let me get back to you by")
    }

    func testFocusChangeBeforeAcceptInsertsNothing() async {
        let rig = Rig(before: "Let me get back to you by")
        FakeLlamaServer.reset(model: " the end of the day")
        rig.controller.noteTyped("y")
        let ready = await waitUntil { rig.controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        rig.focus.current = FocusTarget(appIdentifier: "com.apple.TextEdit", windowIdentity: 9, elementIdentity: 9, selection: .unsupported)
        rig.controller.accept()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.editor.string, "Let me get back to you by")
    }

    func testColdModelAsksLocalModelsToLoadAndSaysSo() async {
        let rig = Rig(before: "Let me get back to you by")
        FakeLlamaServer.reset(model: " the end", warm: false)
        rig.controller.noteTyped("y")
        let failed = await waitUntil { rig.controller.lastError != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(rig.controller.lastError, "gemma-it is loading in Local Models. Suggestions start in a few seconds.")
        XCTAssertEqual(FakeLlamaServer.completionRequests, 0)
        await rig.warmer.lastSend?.value
        XCTAssertEqual(rig.warmRequests.values.count, 1)
        let warm = rig.warmRequests.values.first
        XCTAssertEqual(warm?.url?.path, "/v1/warm")
        XCTAssertEqual(rig.editor.string, "Let me get back to you by")
    }

    // MARK: Helpers

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

// MARK: - Rig: controller + in-process editor + production engine over a fake server

@MainActor
private final class Rig {
    let editor: NSTextView
    let renderer = SpyRenderer()
    let focus = StubFocusIdentityProvider(FocusTarget(
        appIdentifier: "com.example.editor", windowIdentity: 1, elementIdentity: 2, selection: .unsupported
    ))
    let warmRequests = RequestLog()
    let warmer: LocalModelsWarmer
    let controller: CompletionController

    init(
        before: String,
        after: String = "",
        style: PromptStyle = .continuation,
        length: SuggestionLength = .medium,
        autoSuggest: Bool = true
    ) {
        editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.string = before + after
        editor.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))

        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        defaults.set(autoSuggest, forKey: CompletionController.autoSuggestKey)
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)
        defaults.set(style.rawValue, forKey: PromptStyle.defaultsKey)
        defaults.set(length.rawValue, forKey: SuggestionLength.defaultsKey)

        let session = FakeLlamaServer.session()
        let log = warmRequests
        let warmer = LocalModelsWarmer(transport: { request, _ in log.append(request) })
        self.warmer = warmer
        let engine = LocalModelsCompletionEngine(
            modelAlias: "gemma-it",
            maxTokens: length.maxTokens,
            temperature: 0,
            statusClient: LocalModelsStatusClient(session: session),
            warmer: warmer,
            engineFactory: { baseURL, model in
                OpenAICompatibleEngine(name: "fake-llama", baseURL: baseURL, model: model,
                                       maxTokens: length.maxTokens, temperature: 0, session: session)
            }
        )
        let editor = self.editor
        controller = CompletionController(
            engineManager: EngineManager(modelPathOverride: "/fake/model.gguf", engineFactory: { _ in MockClosableEngine() }),
            personalization: makePersonalizationStore("e2e"),
            overrides: AppOverridesStore(fileURL: tempFileURL("e2e-overrides")),
            inserter: TextViewInserter(editor: editor),
            renderer: renderer,
            daemonEngineProvider: { _ in engine },
            contextProviderOverride: TextViewContextProvider(editor: editor),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: focus,
            userDefaults: defaults
        )
        controller.debounceInterval = 0.02
        controller.cooldownInterval = 0.02
    }
}

/// Reads prefix/suffix at the caret of an in-process text view, like the AX
/// provider does for a real field.
private struct TextViewContextProvider: ContextProvider {
    let editor: NSTextView

    func provideContext(for request: CompletionRequest) async throws -> CompletionContext {
        await MainActor.run {
            let text = editor.string as NSString
            let caret = editor.selectedRange().location
            return CompletionContext(
                prefix: text.substring(to: caret),
                suffix: text.substring(from: caret),
                appIdentifier: request.appIdentifier
            )
        }
    }
}

/// Inserts accepted text at the caret of the in-process text view, the way the
/// AX inserter replaces the selected range of a real field.
private final class TextViewInserter: CompletionInserter, @unchecked Sendable {
    // Only touched on the main actor.
    let editor: NSTextView
    init(editor: NSTextView) { self.editor = editor }

    func insert(_ text: String) async throws {
        await MainActor.run {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }
}

/// Records what the overlay would draw.
private final class SpyRenderer: CompletionRenderer, @unchecked Sendable {
    // Only touched on the main actor (the controller renders from it).
    private(set) var ghost: String?
    func present(_ candidate: String, for request: CompletionRequest) { ghost = candidate.isEmpty ? nil : candidate }
    func clear() { ghost = nil }
}

private final class RequestLog: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var values: [URLRequest] { lock.withLock { requests } }
}

// MARK: - Fake llama-server + Local Models control plane

private final class FakeLlamaServer: URLProtocol {
    // Test-only shared state; the e2e tests run serially on the main actor.
    nonisolated(unsafe) static var model = ""
    nonisolated(unsafe) static var warm = true
    nonisolated(unsafe) static var completionRequests = 0
    nonisolated(unsafe) static var lastCompletionBody: [String: Any]?

    static func reset(model: String, warm: Bool = true) {
        self.model = model
        self.warm = warm
        completionRequests = 0
        lastCompletionBody = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeLlamaServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        switch path {
        case "/v1/models":
            let body = """
            {"default":"qwen3-vl","models":[{"id":"gemma-it","warm":\(Self.warm),"endpoint":"http://127.0.0.1:8079"}]}
            """
            respond(Data(body.utf8), contentType: "application/json")
        case "/v1/completions":
            Self.completionRequests += 1
            let body = jsonBody()
            Self.lastCompletionBody = body
            let stops = body["stop"] as? [String] ?? []
            var text = Self.model
            for stop in stops where !stop.isEmpty {
                if let range = text.range(of: stop) { text = String(text[..<range.lowerBound]) }
            }
            if body["grammar"] != nil, !text.isEmpty, !text.hasPrefix(" ") {
                // A grammar-constrained server can never produce this.
                text = " " + text
            }
            streamSSE(Self.tokens(text).map { #"{"choices":[{"text":\#(Self.jsonString($0)),"index":0}]}"# })
        case "/v1/chat/completions":
            Self.completionRequests += 1
            Self.lastCompletionBody = jsonBody()
            streamSSE(Self.tokens(Self.model).map { #"{"choices":[{"delta":{"content":\#(Self.jsonString($0))},"index":0}]}"# })
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    /// Split like a tokenizer: pieces carry their leading space.
    static func tokens(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for c in text {
            if c == " ", !current.isEmpty, current != " " {
                pieces.append(current)
                current = ""
            }
            current.append(c)
            if current.count >= 4, !(c == " ") {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func jsonBody() -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                buffer.append(chunk, count: n)
            }
            stream.close()
            data = buffer
        }
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private func respond(_ data: Data, contentType: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func streamSSE(_ events: [String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for event in events {
            client?.urlProtocol(self, didLoad: Data("data: \(event)\n\n".utf8))
        }
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
