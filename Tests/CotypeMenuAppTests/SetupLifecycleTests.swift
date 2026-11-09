import AppKit
import XCTest
import CotypeCore
@testable import CotypeMenuApp

@MainActor
final class SetupLifecycleTests: XCTestCase {
    func testPermissionMonitoringStopsAndRestartsWithoutDuplicateObservers() {
        let notifications = NotificationCenter()
        var reads = 0
        var granted = false
        let monitor = PermissionMonitor(notifications: notifications) {
            reads += 1
            return (granted, granted, granted)
        }
        XCTAssertEqual(reads, 1)
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(reads, 2)
        granted = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(monitor.hasAccessibility)
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(reads, 3)
        granted = false
        monitor.start()
        XCTAssertFalse(monitor.hasAccessibility)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(reads, 5)
        monitor.stop()
    }

    func testReturningToIdenticalPracticeTextCannotPublishRetiredResult() async {
        let first = AsyncThrowingStream<CompletionEvent, Error>.makeStream()
        let next = AsyncThrowingStream<CompletionEvent, Error>.makeStream()
        let firstStarted = expectation(description: "first practice stream")
        let nextStarted = expectation(description: "replacement practice stream")
        let engine = PracticeTestEngine(streams: [first.stream, next.stream], started: [firstStarted, nextStarted])
        let model = PracticeCompletionModel(debounce: .zero, engine: { engine })
        var successes = 0
        model.text = "A synthetic sentence "
        model.scheduleCompletion(for: model.text, daemonReady: true) { successes += 1 }
        let retired = model.completionTask
        await fulfillment(of: [firstStarted], timeout: 2)

        model.text = "A different synthetic sentence "
        model.scheduleCompletion(for: model.text, daemonReady: false) { successes += 1 }
        model.text = "A synthetic sentence "
        model.scheduleCompletion(for: model.text, daemonReady: true) { successes += 1 }
        let current = model.completionTask
        await fulfillment(of: [nextStarted], timeout: 2)
        first.continuation.yield(.token("retired output"))
        first.continuation.finish()
        await retired?.value
        XCTAssertTrue(model.isRunning, "retired cleanup must not stop the current request")
        XCTAssertTrue(model.candidate.isEmpty)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(successes, 0)

        next.continuation.yield(.token("continues clearly."))
        next.continuation.finish()
        await current?.value
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(model.succeeded)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.candidate.isEmpty)
    }

    func testPracticeDisappearanceCannotBecomeAnErrorOrSuccess() async {
        let stream = AsyncThrowingStream<CompletionEvent, Error>.makeStream()
        let started = expectation(description: "practice stream")
        let engine = PracticeTestEngine(streams: [stream.stream], started: [started])
        let model = PracticeCompletionModel(debounce: .zero, engine: { engine })
        var successes = 0
        model.text = "Another synthetic sentence "
        model.scheduleCompletion(for: model.text, daemonReady: true) { successes += 1 }
        let task = model.completionTask
        await fulfillment(of: [started], timeout: 2)
        model.cancel()
        stream.continuation.finish(throwing: PracticeCompletionError.empty)
        await task?.value
        XCTAssertEqual(successes, 0)
        XCTAssertFalse(model.succeeded)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.errorText)
    }

    func testPracticeEndFinalizesBeforeLateTransportError() async {
        let stream = AsyncThrowingStream<CompletionEvent, Error>.makeStream()
        let started = expectation(description: "practice stream")
        let engine = PracticeTestEngine(streams: [stream.stream], started: [started])
        let model = PracticeCompletionModel(debounce: .zero, engine: { engine })
        var successes = 0
        model.text = "A synthetic sentence "
        model.scheduleCompletion(for: model.text, daemonReady: true) { successes += 1 }
        let task = model.completionTask
        await fulfillment(of: [started], timeout: 2)
        stream.continuation.yield(.token("continues clearly."))
        stream.continuation.yield(.end)
        stream.continuation.finish(throwing: PracticeCompletionError.empty)
        await task?.value
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(model.succeeded)
        XCTAssertNil(model.errorText)
    }
}

/// The test transport owns only synthetic streams. Its index is lock-guarded
/// because an engine's interface is not actor-isolated.
private final class PracticeTestEngine: InferenceEngine {
    let name = "practice-test"
    private let lock = NSLock()
    private let streams: [AsyncThrowingStream<CompletionEvent, Error>]
    private let started: [XCTestExpectation]
    private var index = 0

    init(streams: [AsyncThrowingStream<CompletionEvent, Error>], started: [XCTestExpectation]) {
        self.streams = streams
        self.started = started
    }

    func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        lock.lock()
        let current = index
        index += 1
        lock.unlock()
        guard streams.indices.contains(current) else {
            return AsyncThrowingStream { $0.finish(throwing: PracticeCompletionError.empty) }
        }
        started[current].fulfill()
        return streams[current]
    }
}
