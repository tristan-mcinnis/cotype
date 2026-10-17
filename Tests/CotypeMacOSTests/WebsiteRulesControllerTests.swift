import AppKit
import XCTest
import CotypeCore
@testable import CotypeMacOS

/// Website rules are only as safe as the identity that selects them. These tests
/// drive the real controller with an injected host so navigation, ambiguity and
/// per-site instructions are deterministic.
@MainActor
final class WebsiteRulesControllerTests: XCTestCase {

    private static let browser = "com.google.Chrome"

    /// A host that the test can change, standing in for the browser window.
    private final class MutableDomain: BrowserDomainProviding, @unchecked Sendable {
        var host: String?
        init(_ host: String?) { self.host = host }
        func currentDomain(appIdentifier: String) -> String? {
            AppCompatibility.isBrowser(appIdentifier) ? host : nil
        }
    }

    /// Records the prompt the controller actually built.
    private final class RecordingEngine: InferenceEngine, @unchecked Sendable {
        let name = "recording"
        private(set) var prompts: [Prompt] = []
        func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
            prompts.append(prompt)
            return AsyncThrowingStream { continuation in
                continuation.yield(.token("hello there"))
                continuation.yield(.end)
                continuation.finish()
            }
        }
    }

    private func makeController(
        domain: MutableDomain,
        rules: WebsiteRulesStore,
        overrides: AppOverridesStore = AppOverridesStore(fileURL: tempFileURL("website-overrides")),
        engine: InferenceEngine? = nil,
        style: PromptStyle = .continuation,
        globalPrompt: String? = nil
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        defaults.set(style.rawValue, forKey: PromptStyle.defaultsKey)
        if let globalPrompt { defaults.set(globalPrompt, forKey: "systemPrompt") }
        let inserter = RecordingInserter()
        let controller = CompletionController(
            engineManager: EngineManager(
                modelPathOverride: "/fake/model.gguf",
                engineFactory: { _ in MockClosableEngine() }
            ),
            personalization: makePersonalizationStore(),
            overrides: overrides,
            websiteRules: rules,
            browserDomainProvider: domain,
            inserter: inserter,
            renderer: VisibleSpyRenderer(),
            pipelineEngineOverride: engine ?? MockInferenceEngine(response: "hello there", wordDelayNanoseconds: 0),
            frontmostAppProvider: { Self.browser },
            focusIdentityProvider: StubFocusIdentityProvider(FocusTarget(
                appIdentifier: Self.browser,
                windowIdentity: 1,
                elementIdentity: 2,
                selection: .unsupported
            )),
            userDefaults: defaults
        )
        controller.debounceInterval = 0.02
        controller.cooldownInterval = 0.02
        return (controller, inserter)
    }

    private func makeRules() -> (WebsiteRulesStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-site-\(UUID().uuidString).json")
        return (WebsiteRulesStore(fileURL: url), url)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testDisabledWebsiteRefusesGeneration() async {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        rules.setRule(WebsiteRule(enabled: false), forHost: "example.com")
        let (controller, inserter) = makeController(domain: MutableDomain("example.com"), rules: rules)

        XCTAssertFalse(controller.trigger())
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastError, "Completions are off for example.com.")
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    /// No trustworthy identity means no site rule. A rule for example.com must
    /// not influence a page whose host could not be read.
    func testUnknownIdentityFallsBackToTheAppPolicy() async {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        rules.setRule(WebsiteRule(enabled: false), forHost: "example.com")
        let (controller, _) = makeController(domain: MutableDomain(nil), rules: rules)

        XCTAssertTrue(controller.trigger(), "an unknown host must not disable the app")
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertNil(controller.lastError)
    }

    func testSubdomainInheritsTheParentRule() async {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        rules.setRule(WebsiteRule(enabled: false), forHost: "example.com")
        let (controller, _) = makeController(domain: MutableDomain("mail.example.com"), rules: rules)

        XCTAssertFalse(controller.trigger())
        XCTAssertEqual(controller.lastError, "Completions are off for example.com.")
    }

    /// A navigation between generation and accept invalidates the site rule the
    /// candidate was generated under, so nothing is inserted.
    func testNavigationBeforeAcceptFailsClosed() async {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        let domain = MutableDomain("example.com")
        let (controller, inserter) = makeController(domain: domain, rules: rules)

        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)

        domain.host = "elsewhere.test"
        controller.accept()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(inserter.inserted.isEmpty, "a navigated tab must not receive the old candidate")
        XCTAssertFalse(controller.hasPendingCompletion)
    }

    func testUnchangedIdentityAcceptsNormally() async {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        let (controller, inserter) = makeController(domain: MutableDomain("example.com"), rules: rules)

        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.isAcceptKeyReady }
        XCTAssertTrue(ready)
        controller.accept()
        let inserted = await waitUntil { !inserter.inserted.isEmpty }
        XCTAssertTrue(inserted)
        XCTAssertEqual(inserter.inserted, ["hello there"])
    }

    /// A site's instructions are the instruction lane's system message. The
    /// continuation lane does not send them: it continues any prose it is given.
    func testSiteInstructionsReachTheInstructionSystemMessageOnly() async throws {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        rules.setRule(
            WebsiteRule(enabled: true, systemPrompt: "This site is a support inbox. Be concise."),
            forHost: "example.com"
        )
        let overrides = AppOverridesStore(fileURL: tempFileURL("site-precedence"))
        overrides.setOverride(AppOverride(enabled: true, systemPrompt: "App-level note."), for: Self.browser)

        let instructionEngine = RecordingEngine()
        let (instruction, _) = makeController(
            domain: MutableDomain("example.com"),
            rules: rules,
            overrides: overrides,
            engine: instructionEngine,
            style: .instruction,
            globalPrompt: "Global note."
        )
        XCTAssertTrue(instruction.trigger())
        _ = await waitUntil { instruction.phase == .awaitingAccept }
        let system = instructionEngine.prompts.first?.system ?? ""
        XCTAssertTrue(system.contains("Be concise."), "the site wins over app and global")
        XCTAssertFalse(system.contains("App-level note."))
        XCTAssertFalse(system.contains("Global note."))

        let continuationEngine = RecordingEngine()
        let (continuation, _) = makeController(
            domain: MutableDomain("example.com"),
            rules: rules,
            overrides: overrides,
            engine: continuationEngine
        )
        XCTAssertTrue(continuation.trigger())
        _ = await waitUntil { continuation.phase == .awaitingAccept }
        let sent = continuationEngine.prompts.first?.continuation?.text ?? ""
        XCTAssertNotNil(continuationEngine.prompts.first?.continuation)
        XCTAssertFalse(sent.contains("Be concise."))
        XCTAssertFalse(sent.contains("App-level note."))
    }

    /// Precedence is identical in both lanes: site, then app, then global.
    func testAppOverrideFallsBackWhenNoSiteRuleMatches() async throws {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        let overrides = AppOverridesStore(fileURL: tempFileURL("app-precedence"))
        overrides.setOverride(AppOverride(enabled: true, systemPrompt: "Use the house voice."), for: Self.browser)
        let engine = RecordingEngine()
        let (controller, _) = makeController(
            domain: MutableDomain("other.test"),
            rules: rules,
            overrides: overrides,
            engine: engine,
            style: .instruction,
            globalPrompt: "Global note."
        )

        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        let system = engine.prompts.first?.system ?? ""
        XCTAssertTrue(system.contains("Use the house voice."))
        XCTAssertFalse(system.contains("Global note."))
    }

    func testGlobalInstructionIsTheLastFallback() async throws {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingEngine()
        let (controller, _) = makeController(
            domain: MutableDomain("other.test"),
            rules: rules,
            engine: engine,
            style: .instruction,
            globalPrompt: "Global note."
        )

        XCTAssertTrue(controller.trigger())
        _ = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(engine.prompts.first?.system.contains("Global note.") ?? false)
    }

    func testNonBrowserAppNeverConsultsWebsiteIdentity() async {
        let (rules, url) = makeRules()
        defer { try? FileManager.default.removeItem(at: url) }
        rules.setRule(WebsiteRule(enabled: false), forHost: "example.com")
        let defaults = makeUserDefaults()
        defaults.set(true, forKey: "enableCompletions")
        let inserter = RecordingInserter()
        // A provider that would answer with a host even for a non-browser; the
        // controller must not ask it, because the app is not a browser.
        let controller = CompletionController(
            engineManager: EngineManager(
                modelPathOverride: "/fake/model.gguf",
                engineFactory: { _ in MockClosableEngine() }
            ),
            personalization: makePersonalizationStore(),
            overrides: AppOverridesStore(fileURL: tempFileURL("nonbrowser-overrides")),
            websiteRules: rules,
            browserDomainProvider: AlwaysHostProvider(host: "example.com"),
            inserter: inserter,
            pipelineEngineOverride: MockInferenceEngine(response: "hello", wordDelayNanoseconds: 0),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(FocusTarget(
                appIdentifier: "com.example.editor",
                windowIdentity: 1,
                elementIdentity: 2,
                selection: .unsupported
            )),
            userDefaults: defaults
        )
        XCTAssertTrue(controller.trigger(), "a website rule must not disable a non-browser app")
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
    }
}

/// Answers with a host regardless of the app: only the controller's browser
/// check stands between it and a website rule.
private struct AlwaysHostProvider: BrowserDomainProviding {
    let host: String
    func currentDomain(appIdentifier: String) -> String? { host }
}

/// A renderer that reports visibility in-process (no window), so controller
/// tests exercise the invariant without AppKit geometry.
final class VisibleSpyRenderer: CompletionRenderer, @unchecked Sendable {
    private(set) var ghost: String?

    func present(_ candidate: String, for request: CompletionRequest) {
        ghost = candidate.isEmpty ? nil : candidate
    }

    func clear() { ghost = nil }
}
