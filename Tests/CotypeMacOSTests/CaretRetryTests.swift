import XCTest
import AppKit
import CotypeCore
@testable import CotypeMacOS

@MainActor
final class CaretRetryTests: XCTestCase {

    private final class ScriptedGeometry: InlineCaretGeometryProvider, InlineFieldGeometryProvider {
        var missesRemaining: Int
        var field: CaretFieldGeometry?
        private(set) var calls = 0
        private static let metrics = GhostTextMetrics(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        private let geometry = CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
            metrics: ScriptedGeometry.metrics
        )

        init(misses: Int, fieldOnly: Bool = false) {
            missesRemaining = misses
            if fieldOnly {
                field = CaretFieldGeometry(fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200), metrics: Self.metrics)
            }
        }

        func caretGeometry() -> CaretGeometry? {
            calls += 1
            if missesRemaining > 0 {
                missesRemaining -= 1
                return nil
            }
            return geometry
        }

        func fieldGeometry() -> CaretFieldGeometry? { field }
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

        func fireAll() {
            while !queue.isEmpty { fireNext() }
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

    /// The coalesced drain runs inline, so the first attempt has happened by the
    /// time `present` returns; only retries wait for the manual scheduler.
    private func makeRig(
        misses: Int,
        plan: CaretRetryPlan = .standard,
        fallback: Bool = false
    ) -> Rig {
        let geometry = ScriptedGeometry(misses: misses, fieldOnly: fallback)
        let scheduler = ManualScheduler()
        let renderer = GhostTextRenderer(
            geometryProvider: geometry,
            maxLines: 3,
            fallbackEnabled: { fallback },
            caretRetry: plan,
            retryScheduler: { scheduler.schedule($0, $1) },
            redrawScheduler: { $0() }
        )
        let notShown = Recorder<NotShownReason>()
        let visibility = Recorder<Bool>()
        renderer.onNotShown = { notShown.values.append($0) }
        renderer.onVisibilityChanged = { visibility.values.append($0) }
        return Rig(renderer: renderer, geometry: geometry, scheduler: scheduler, notShown: notShown, visibility: visibility)
    }

    func testStandardPlanStaysUnderTheLatencyBudget() {
        XCTAssertFalse(CaretRetryPlan.standard.delays.isEmpty)
        XCTAssertLessThan(CaretRetryPlan.standard.delays.reduce(0, +), 0.25)
    }

    func testTwoMissesThenGeometryEndsShownAndReportsNoFailure() {
        let rig = makeRig(misses: 2)
        defer { rig.renderer.clear() }
        rig.renderer.present("hello")
        XCTAssertFalse(rig.renderer.isShowing, "nothing is drawn while the caret is still unknown")
        XCTAssertEqual(rig.scheduler.pendingCount, 1)

        rig.scheduler.fireNext()
        XCTAssertFalse(rig.renderer.isShowing)
        rig.scheduler.fireNext()

        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["hello"])
        XCTAssertEqual(rig.scheduler.delays, Array(CaretRetryPlan.standard.delays.prefix(2)))
        XCTAssertTrue(rig.notShown.values.isEmpty)
        XCTAssertEqual(rig.visibility.values.last, true)
    }

    func testAlwaysNilReportsNotShownOnceAndStaysHidden() {
        let rig = makeRig(misses: .max)
        rig.renderer.present("hello")
        XCTAssertTrue(rig.notShown.values.isEmpty, "no verdict until the last attempt has run")

        rig.scheduler.fireAll()

        XCTAssertEqual(rig.geometry.calls, CaretRetryPlan.standard.delays.count + 1)
        XCTAssertEqual(rig.scheduler.delays, CaretRetryPlan.standard.delays)
        XCTAssertEqual(rig.notShown.values, [.noCaretGeometry])
        XCTAssertFalse(rig.renderer.isShowing)
        XCTAssertFalse(rig.visibility.values.contains(true))
    }

    func testNoRetryPlanReportsAtTheFirstMiss() {
        let rig = makeRig(misses: .max, plan: .none)
        rig.renderer.present("hello")
        XCTAssertEqual(rig.notShown.values, [.noCaretGeometry])
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
    }

    func testStaleGhostIsNeverReportedVisibleDuringARetry() {
        let rig = makeRig(misses: 0)
        defer { rig.renderer.clear() }
        rig.renderer.present("hello")
        XCTAssertTrue(rig.renderer.isShowing)

        rig.geometry.missesRemaining = 1
        rig.renderer.present("hello there")

        XCTAssertFalse(rig.renderer.isShowing, "the window still shows the old candidate")
        XCTAssertEqual(rig.visibility.values.last, false, "accept must not insert a candidate the user cannot see")
        XCTAssertTrue(rig.notShown.values.isEmpty, "a non-final miss is not yet a failure")
        XCTAssertEqual(rig.scheduler.pendingCount, 1)

        rig.scheduler.fireNext()
        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertEqual(rig.visibility.values.last, true)
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text).joined(), "hello there")
        XCTAssertTrue(rig.notShown.values.isEmpty)
    }

    func testGhostReportsNotShownOnlyAtTheFinalMiss() {
        let rig = makeRig(misses: 0)
        rig.renderer.present("hello")
        rig.geometry.missesRemaining = .max
        rig.renderer.present("hello there")

        for _ in 1..<CaretRetryPlan.standard.delays.count { rig.scheduler.fireNext() }
        XCTAssertFalse(rig.renderer.isShowing)
        XCTAssertTrue(rig.notShown.values.isEmpty)

        rig.scheduler.fireNext()
        XCTAssertFalse(rig.renderer.isShowing)
        XCTAssertEqual(rig.visibility.values.last, false)
        XCTAssertEqual(rig.notShown.values, [.noCaretGeometry])
    }

    func testFallbackShowsAtOnceAndStaysVisibleAcrossAnUpdate() {
        let rig = makeRig(misses: .max, fallback: true)
        defer { rig.renderer.clear() }
        rig.renderer.present("hello")
        XCTAssertTrue(rig.renderer.isShowing, "the fallback must not wait for the retries")
        XCTAssertTrue(rig.renderer.isFallbackPreview)

        rig.renderer.present("hello there")
        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["hello there"])

        rig.scheduler.fireAll()
        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertTrue(rig.renderer.isFallbackPreview)
        XCTAssertFalse(rig.visibility.values.contains(false), "a Tab during any update must reach Cotype, not the shell")
        XCTAssertTrue(rig.notShown.values.isEmpty)
    }

    func testFallbackUpgradesToInlineWhenTheCaretResolves() {
        let rig = makeRig(misses: 1, fallback: true)
        defer { rig.renderer.clear() }
        rig.renderer.present("hello")
        XCTAssertTrue(rig.renderer.isFallbackPreview)

        rig.scheduler.fireNext()
        XCTAssertTrue(rig.renderer.isShowing)
        XCTAssertFalse(rig.renderer.isFallbackPreview)
        XCTAssertEqual(rig.renderer.ghostContent.lines.first?.xOffset, 50, "the inline ghost sits at the caret")
    }

    func testClearDuringRetryCancelsIt() {
        let rig = makeRig(misses: .max)
        rig.renderer.present("hello")
        let callsBefore = rig.geometry.calls

        rig.renderer.clear()
        rig.scheduler.fireNext()

        XCTAssertEqual(rig.geometry.calls, callsBefore, "a cleared show must not look for the caret again")
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
        XCTAssertTrue(rig.notShown.values.isEmpty)
        XCTAssertFalse(rig.renderer.isShowing)
    }

    func testNewerPresentSupersedesTheOldRetry() {
        let rig = makeRig(misses: 1)
        defer { rig.renderer.clear() }
        rig.renderer.present("old")
        XCTAssertEqual(rig.scheduler.pendingCount, 1)

        rig.renderer.present("new")
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["new"])
        let callsBefore = rig.geometry.calls

        rig.scheduler.fireNext()

        XCTAssertEqual(rig.geometry.calls, callsBefore, "the superseded retry must not draw")
        XCTAssertEqual(rig.renderer.ghostContent.lines.map(\.text), ["new"])
        XCTAssertTrue(rig.notShown.values.isEmpty)
    }

    func testRenderGuardIsRecheckedBeforeEachRetry() {
        let rig = makeRig(misses: .max)
        var allowed = true
        rig.renderer.renderGuard = { allowed }
        rig.renderer.present("hello")
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
