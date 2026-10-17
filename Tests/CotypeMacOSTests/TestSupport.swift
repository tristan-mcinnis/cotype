import XCTest
import CotypeCore
@testable import CotypeMacOS

// MARK: - Shared test doubles and helpers

/// A mock engine that implements `EngineClosable` so `EngineManager` lifecycle
/// can be tested without a real model.
final class MockClosableEngine: EngineClosable, @unchecked Sendable {
    let name: String
    let response: String
    private var isClosed = false
    private let lock = NSLock()

    init(name: String = "mock-closable", response: String = "hello") {
        self.name = name
        self.response = response
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }

    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.yield(.end)
            continuation.finish()
        }
    }
}

/// An inset that records what was inserted and into which app.
final class RecordingInserter: CompletionInserter, @unchecked Sendable {
    var inserted: [String] = []
    var insertedApps: [String?] = []
    func insert(_ text: String) async throws { inserted.append(text); insertedApps.append(nil) }
    func insert(_ text: String, appIdentifier: String?) async throws {
        inserted.append(text); insertedApps.append(appIdentifier)
    }
}

/// An engine that returns a scripted sequence of responses, one per call, with a
/// per-token delay so supersession timing can be controlled.
final class ScriptedEngine: InferenceEngine, @unchecked Sendable {
    let name = "scripted"
    let responses: [String]
    let wordDelayNanoseconds: UInt64
    private var callIndex = 0
    private let lock = NSLock()

    init(_ responses: [String], wordDelayNanoseconds: UInt64 = 15_000_000) {
        self.responses = responses
        self.wordDelayNanoseconds = wordDelayNanoseconds
    }

    /// How many generation streams have been requested so far. A supersession
    /// test waits for this to reach 1 before firing its second trigger, so the
    /// first generation is genuinely in flight (and has consumed its own
    /// scripted response) instead of racing the cooperative scheduler.
    var callsStarted: Int {
        lock.withLock { callIndex }
    }

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            let response = responses[min(callIndex, responses.count - 1)]
            callIndex += 1
            lock.unlock()
            let task = Task {
                let words = response.split(separator: " ")
                for (i, word) in words.enumerated() {
                    try? await Task.sleep(nanoseconds: wordDelayNanoseconds)
                    if Task.isCancelled { break }
                    continuation.yield(.token(i < words.count - 1 ? "\(word) " : String(word)))
                }
                continuation.yield(.end)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

func makeUserDefaults() -> UserDefaults {
    let name = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func tempFileURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cotype-macos-\(name)-\(UUID().uuidString).json")
}

/// Fully isolated personalization storage for macOS tests. Supplying only the
/// sample URL leaves config and metrics pointed at the real user's Application
/// Support directory, which makes test runs corrupt production usage counts.
func makePersonalizationStore(_ name: String = "personalization") -> PersonalizationStore {
    PersonalizationStore(
        fileURL: tempFileURL("\(name)-samples"),
        configURL: tempFileURL("\(name)-config"),
        metricsURL: tempFileURL("\(name)-metrics")
    )
}

/// A deterministic caret for tests that go through the real ghost renderer.
/// Without it, `AXCaretGeometryProvider` reads the live screen and a test's
/// result depends on which app happens to be frontmost.
struct FixedCaretGeometry: InlineCaretGeometryProvider {
    func caretGeometry() -> CaretGeometry? {
        CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200)
        )
    }
}

/// An isolated website-rules store for controller tests. Never touches
/// `~/Library/Application Support/Cotype`.
func makeWebsiteRulesStore(_ name: String = "website-rules") -> WebsiteRulesStore {
    WebsiteRulesStore(fileURL: tempFileURL(name))
}
