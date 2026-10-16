import XCTest
import CotypeCore
@testable import CotypeMacOS

/// Regression tests for the completion controller's production model source.
///
/// When Local Models daemon mode is on, generation must proceed even with no
/// in-process model path, and must route to the daemon engine seam rather than
/// blocking or silently falling back to the in-process engine. When daemon mode
/// is off, the existing no-model block must still apply. The controller is
/// exercised through an injected daemon-engine provider so no live control plane
/// or llama-server is needed.
@MainActor
final class DaemonRoutingControllerTests: XCTestCase {

    private func makeDefaults(daemonEnabled: Bool) -> UserDefaults {
        let defaults = makeUserDefaults()
        defaults.set(daemonEnabled, forKey: DaemonRoutedEngine.enabledKey)
        defaults.set(true, forKey: "enableCompletions")
        return defaults
    }

    /// Production-shaped daemon provider but returning a deterministic mock:
    /// mirrors `DaemonRoutedEngine.isDaemonMode` (only present when the toggle is
    /// on) without a real control plane or llama-server.
    private func mockDaemonProvider(response: String) -> (UserDefaults) -> InferenceEngine? {
        { defaults in
            defaults.bool(forKey: DaemonRoutedEngine.enabledKey)
                ? MockInferenceEngine(response: response, wordDelayNanoseconds: 0)
                : nil
        }
    }

    private func makeController(
        modelPath: String?,
        daemonEnabled: Bool,
        daemonResponse: String?,
        localEngineResponse: String = "LOCAL-ENGINE"
    ) -> (CompletionController, RecordingInserter) {
        let defaults = makeDefaults(daemonEnabled: daemonEnabled)
        let personalization = makePersonalizationStore()
        let overrides = AppOverridesStore(fileURL: tempFileURL("overrides"))
        let inserter = RecordingInserter()
        let engineManager = EngineManager(
            modelPathOverride: modelPath,
            engineFactory: { _ in MockClosableEngine(response: localEngineResponse) }
        )
        // `EngineManager(modelPathOverride: nil)` falls back to a real default
        // model path, so force a genuinely absent path for the no-local-model case.
        if modelPath == nil { engineManager.refreshToPath(nil) }
        let controller = CompletionController(
            engineManager: engineManager,
            personalization: personalization,
            overrides: overrides,
            inserter: inserter,
            daemonEngineProvider: daemonResponse.map(mockDaemonProvider) ?? { _ in nil },
            contextProviderOverride: StaticContextProvider(),
            frontmostAppProvider: { "com.example.editor" },
            focusIdentityProvider: StubFocusIdentityProvider(
                FocusTarget(
                    appIdentifier: "com.example.editor",
                    windowIdentity: 1,
                    elementIdentity: 1,
                    selection: .unsupported
                )
            ),
            userDefaults: defaults
        )
        return (controller, inserter)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testDaemonModeAllowsGenerationWithoutLocalModel() async {
        // Daemon on, no in-process model path: generation must proceed and reach the
        // routed daemon seam, proving it does not require a Cotype-managed model.
        let (controller, _) = makeController(
            modelPath: nil,
            daemonEnabled: true,
            daemonResponse: "daemon-draft"
        )
        XCTAssertTrue(controller.trigger(), "daemon mode should allow generation without a local model path")
        XCTAssertEqual(controller.phase, .generating)
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready, "the daemon seam must produce a candidate")
        XCTAssertEqual(controller.currentCandidate, "daemon-draft")
        XCTAssertNil(controller.lastError)
    }

    func testNoDaemonModeBlocksGenerationWithoutLocalModel() {
        // Daemon off, no in-process model path: the classic no-model block must still apply.
        let (controller, _) = makeController(modelPath: nil, daemonEnabled: false, daemonResponse: nil)
        XCTAssertFalse(controller.trigger(), "without daemon mode and no model path, generation must be blocked")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastError, "No model installed. Open Cotype Setup to install the local model.")
    }

    func testDaemonModeRoutesToDaemonOverLocalModel() async {
        // Even when an in-process model IS available, daemon mode must prefer the
        // routed daemon seam and never silently serve from the local engine.
        let (controller, _) = makeController(
            modelPath: "/fake/model.gguf",
            daemonEnabled: true,
            daemonResponse: "daemon-draft",
            localEngineResponse: "LOCAL-ENGINE"
        )
        XCTAssertTrue(controller.trigger())
        let ready = await waitUntil { controller.phase == .awaitingAccept }
        XCTAssertTrue(ready)
        XCTAssertEqual(
            controller.currentCandidate,
            "daemon-draft",
            "daemon mode must serve from the daemon seam, not the in-process engine"
        )
    }
}
