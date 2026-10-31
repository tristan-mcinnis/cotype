import XCTest
import AppKit
import CotypeCore
@testable import CotypeMacOS

@MainActor
final class CaretRetryTests: XCTestCase {

    private final class ScriptedGeometry: InlineCaretGeometryProvider {
        var missesRemaining: Int
        private(set) var calls = 0
        private let geometry = CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
            metrics: GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        )

        init(misses: Int) { missesRemaining = misses }

        func caretGeometry() -> CaretGeometry? {
            calls += 1
            if missesRemaining > 0 {
                missesRemaining -= 1
                return nil
            }
            return geometry
        }
    }

    /// Holds scheduled retries so a test fires them by hand, with no real delay.
    private final class ManualScheduler {
        private(set) var delays: [TimeInterval] = []
        private var queue: [() -> Void] = []

        var pendingCount: Int { queue.count }

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            delays.append(delay)
            queue.append(work)
        }

        func fireNext() {
            guard !queue.isEmpty else { return }
            queue.removeFirst()()
        }
    }

    private struct Rig {
        let renderer: GhostTextRenderer
        let geometry: ScriptedGeometry
        let scheduler: ManualScheduler
        let notShown: Recorder<NotShownReason>
        let visibility: Recorder<Bool>
    }

    private final class Recorder<T> {
        var values: [T] = []
    }

    private func makeRig(misses: Int, plan: CaretRetryPlan = .standard) -> Rig {
        let geometry = ScriptedGeometry(misses: misses)
        let scheduler = ManualScheduler()
        let renderer = GhostTextRenderer(
            geometryProvider: geometry,
            maxLines: 3,
            fallbackEnabled: { false },
            caretRetry: plan,
            retryScheduler: { scheduler.schedule($0, $1) }
        )
        let notShown = Recorder<NotShownReason>()
        let visibility = Recorder<Bool>()
        renderer.onNotShown = { notShown.values.append($0) }
        renderer.onVisibilityChanged = { visibility.values.append($0) }
        return Rig(renderer: renderer, geometry: geometry, scheduler: scheduler, notShown: notShown, visibility: visibility)
    }

    /// Pump the main queue so the coalesced drain runs.
    private func drain() async {
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testStandardPlanStaysUnderTheLatencyBudget() {
        XCTAssertEqual(CaretRetryPlan.standard.delays, [0.03, 0.06, 0.12])
        XCTAssertLessThan(CaretRetryPlan.standard.delays.reduce(0, +), 0.25)
    }

    func testTwoMissesThenGeometryEndsShownAndReportsNoFailure() async {
        let rig = makeRig(misses: 2)
        rig.renderer.present("hello", for: CompletionRequest())
        await drain()
        XCTAssertFalse(rig.renderer.isShowing, "nothing is drawn while the caret is still unknown")
        XCTAssertEqual(rig.scheduler.pendingCount, 1)

        rig.scheduler.fireNext()
        XCTAssertFalse(rig.renderer.isShowing)
        rig.scheduler.fireNext()

        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["hello"])
        XCTAssertEqual(rig.scheduler.delays, [0.03, 0.06])
        XCTAssertTrue(rig.notShown.values.isEmpty)
        XCTAssertEqual(rig.visibility.values.last, true)
        rig.renderer.clear()
    }

    func testAlwaysNilReportsNotShownOnceAndStaysHidden() async {
        let rig = makeRig(misses: .max)
        rig.renderer.present("hello", for: CompletionRequest())
        await drain()
        XCTAssertTrue(rig.notShown.values.isEmpty, "no verdict until the last attempt has run")

        while rig.scheduler.pendingCount > 0 { rig.scheduler.fireNext() }

        XCTAssertEqual(rig.geometry.calls, 4)
        XCTAssertEqual(rig.scheduler.delays, CaretRetryPlan.standard.delays)
        XCTAssertEqual(rig.notShown.values, [.noCaretGeometry])
        XCTAssertFalse(rig.renderer.isShowing)
        XCTAssertEqual(rig.visibility.values.last, false)
    }

    func testNoRetryPlanReportsAtTheFirstMiss() async {
        let rig = makeRig(misses: .max, plan: .none)
        rig.renderer.present("hello", for: CompletionRequest())
        await drain()
        XCTAssertEqual(rig.notShown.values, [.noCaretGeometry])
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
    }

    func testMissHidesTheStaleGhostAtOnce() async {
        let rig = makeRig(misses: 0)
        rig.renderer.present("hello", for: CompletionRequest())
        await drain()
        XCTAssertTrue(rig.renderer.isShowing)

        rig.geometry.missesRemaining = 1
        rig.renderer.present("hello there", for: CompletionRequest())
        await drain()

        XCTAssertFalse(rig.renderer.isShowing, "the old position is wrong, so the window must not linger")
        XCTAssertEqual(rig.visibility.values.last, false)
        XCTAssertEqual(rig.scheduler.pendingCount, 1)

        rig.scheduler.fireNext()
        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["hello there"])
        rig.renderer.clear()
    }

    func testClearDuringRetryCancelsIt() async {
        let rig = makeRig(misses: .max)
        rig.renderer.present("hello", for: CompletionRequest())
        await drain()
        let callsBefore = rig.geometry.calls

        rig.renderer.clear()
        await drain()
        rig.scheduler.fireNext()

        XCTAssertEqual(rig.geometry.calls, callsBefore, "a cleared show must not look for the caret again")
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
        XCTAssertTrue(rig.notShown.values.isEmpty)
        XCTAssertFalse(rig.renderer.isShowing)
    }

    func testNewerPresentSupersedesTheOldRetry() async {
        let rig = makeRig(misses: 1)
        rig.renderer.present("old", for: CompletionRequest())
        await drain()
        XCTAssertEqual(rig.scheduler.pendingCount, 1)

        rig.renderer.present("new", for: CompletionRequest())
        await drain()
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["new"])
        let callsBefore = rig.geometry.calls

        rig.scheduler.fireNext()

        XCTAssertEqual(rig.geometry.calls, callsBefore, "the superseded retry must not draw")
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["new"])
        XCTAssertTrue(rig.notShown.values.isEmpty)
        rig.renderer.clear()
    }

    func testRenderGuardIsRecheckedBeforeEachRetry() async {
        let rig = makeRig(misses: .max)
        var allowed = true
        rig.renderer.renderGuard = { allowed }
        rig.renderer.present("hello", for: CompletionRequest())
        await drain()
        let callsBefore = rig.geometry.calls

        allowed = false
        rig.scheduler.fireNext()

        XCTAssertEqual(rig.geometry.calls, callsBefore, "a denied guard must stop before asking for geometry")
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
        XCTAssertTrue(rig.notShown.values.isEmpty)
        XCTAssertFalse(rig.renderer.isShowing)
        XCTAssertEqual(rig.visibility.values.last, false)
    }
}
