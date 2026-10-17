import XCTest
import AppKit
@testable import CotypeMacOS

@MainActor
final class GhostContentViewDrawTests: XCTestCase {

    private let size = NSSize(width: 240, height: 48)

    private func makeView(_ text: String) -> GhostContentView {
        let view = GhostContentView(frame: NSRect(origin: .zero, size: size))
        view.metrics = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 14, weight: .regular))
        view.lines = [(text, 0)]
        return view
    }

    private func makeRep() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        if let data = rep.bitmapData {
            data.update(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        return rep
    }

    private func render(_ view: GhostContentView, into rep: NSBitmapImageRep) {
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    private func alphaMap(_ rep: NSBitmapImageRep) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                out.append(UInt8((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255))
            }
        }
        return out
    }

    func testSecondCandidateLeavesNoPixelsFromTheFirst() {
        let rep = makeRep()
        render(makeView("hello world candidate"), into: rep)
        XCTAssertTrue(alphaMap(rep).contains { $0 > 0 }, "the first candidate must draw ink")

        render(makeView("hi"), into: rep)
        let stacked = alphaMap(rep)

        let fresh = makeRep()
        render(makeView("hi"), into: fresh)
        XCTAssertTrue(stacked == alphaMap(fresh), "a redraw must replace the previous candidate, not paint over it")
    }

    func testEmptyLinesRedrawClearsThePreviousCandidate() {
        let rep = makeRep()
        render(makeView("Anything"), into: rep)
        let view = makeView("")
        view.lines = []
        render(view, into: rep)
        XCTAssertFalse(alphaMap(rep).contains { $0 > 0 }, "no lines must leave a clear surface")
    }

    func testWindowShrinkAndRegrowShowsOnlyTheLatestCandidate() async {
        struct Fixed: InlineCaretGeometryProvider {
            let geometry: CaretGeometry
            func caretGeometry() -> CaretGeometry? { geometry }
        }
        let metrics = GhostTextMetrics(font: .monospacedSystemFont(ofSize: 14, weight: .regular))
        let geometry = CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
            metrics: metrics
        )
        let renderer = GhostTextRenderer(geometryProvider: Fixed(geometry: geometry), maxLines: 3)
        for text in ["hello world candidate", "hi", "draft text"] {
            renderer.show(candidate: text)
            XCTAssertEqual(renderer.ghostContent.lines.map(\.text), [text])
            XCTAssertTrue(renderer.isShowing, "'\(text)' must be visible after show")
            XCTAssertGreaterThan(renderer.window.frame.width, 0)
            XCTAssertTrue(renderer.ghostContent.needsDisplay, "'\(text)' must be marked for display")
        }
        renderer.window.orderOut(nil)
    }
}
