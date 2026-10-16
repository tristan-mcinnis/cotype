import XCTest
@testable import CotypeMacOS
import CotypeCore

/// Live integration: the production DaemonRoutedEngine against the running
/// local-models daemon's llama-server. Opt-in via COTYPE_DAEMON_LIVE=1 so CI
/// and machines without the daemon skip it cleanly.
final class DaemonLiveIntegrationTests: XCTestCase {

    func testLiveDaemonCompletionStreamsTokens() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["COTYPE_DAEMON_LIVE"] == "1",
            "set COTYPE_DAEMON_LIVE=1 with the local-models daemon warm to run"
        )
        let suite = "daemon-live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: DaemonRoutedEngine.enabledKey)

        let engine = DaemonRoutedEngine(
            fallback: MockInferenceEngine(response: "FALLBACK MUST NOT SERVE"),
            defaults: defaults
        )
        let prompt = Prompt(
            system: "You are an autocomplete assistant. Complete the user's text naturally and concisely. Return only the continuation; do not repeat the input.",
            user: "Thanks for joining the call today. I will send over the"
        )

        var text = ""
        var sawEnd = false
        for try await event in engine.stream(prompt: prompt) {
            switch event {
            case .token(let token): text += token
            case .end: sawEnd = true
            }
        }
        XCTAssertTrue(sawEnd, "stream should terminate with .end")
        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "daemon returned an empty completion"
        )
        XCTAssertFalse(text.contains("FALLBACK MUST NOT SERVE"), "fallback served instead of the daemon")
    }
}
