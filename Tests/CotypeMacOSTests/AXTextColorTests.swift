import XCTest
import AppKit
@testable import CotypeMacOS

final class AXTextColorDecodingTests: XCTestCase {

    private let axKey = NSAttributedString.Key(AXFontDecoder.axForegroundColorAttributeName)

    private func rgb(_ color: NSColor?) -> [CGFloat]? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    func testCocoaForegroundColorIsDecoded() {
        let decoded = AXFontDecoder.textColor(fromAttributes: [
            .foregroundColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1),
        ])
        XCTAssertEqual(rgb(decoded)?.map { ($0 * 100).rounded() }, [20, 40, 60, 100])
    }

    func testAccessibilityCGColorIsDecoded() {
        let cg = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let decoded = AXFontDecoder.textColor(fromAttributes: [axKey: cg])
        XCTAssertEqual(rgb(decoded)?.map { ($0 * 100).rounded() }, [90, 10, 10, 100])
    }

    func testCocoaColorWinsOverTheAccessibilityKey() {
        let decoded = AXFontDecoder.textColor(fromAttributes: [
            .foregroundColor: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
            axKey: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        ])
        XCTAssertEqual(rgb(decoded)?.map { $0.rounded() }, [0, 1, 0, 1])
    }

    func testMissingOrWrongTypeYieldsNil() {
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [:]))
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [axKey: "red"]))
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [axKey: NSNumber(value: 1)]))
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [.foregroundColor: "red"]))
    }

    func testTransparentAndFaintColoursAreRejected() {
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [.foregroundColor: NSColor.clear]))
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [
            axKey: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.49),
        ]))
        XCTAssertNotNil(AXFontDecoder.textColor(fromAttributes: [
            axKey: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5),
        ]))
    }

    func testPatternColourIsRejected() {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        XCTAssertNil(AXFontDecoder.textColor(fromAttributes: [.foregroundColor: NSColor(patternImage: image)]))
    }

    func testStyleReadsFontAndColourFromOneRun() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributed = NSAttributedString(string: "x", attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        ])
        let style = AXFontDecoder.style(from: attributed)
        XCTAssertEqual(style?.font?.pointSize, 13)
        XCTAssertEqual(rgb(style?.color)?.first, 1)
    }

    func testColourWithoutAFontStillYieldsAStyle() {
        let attributed = NSAttributedString(string: "x", attributes: [
            .foregroundColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        ])
        let style = AXFontDecoder.style(from: attributed)
        XCTAssertNil(style?.font)
        XCTAssertNotNil(style?.color)
    }

    func testStyleIsNilWhenNothingIsUsable() {
        XCTAssertNil(AXFontDecoder.style(from: NSAttributedString(string: "")))
        XCTAssertNil(AXFontDecoder.style(from: NSAttributedString(string: "x", attributes: [.foregroundColor: NSColor.clear])))
    }
}

@MainActor
final class GhostTextColorDrawTests: XCTestCase {

    private let size = NSSize(width: 240, height: 48)

    /// The inkiest pixel of the rendered ghost, as sRGB components.
    private func strongestInk(textColor: NSColor?) -> [CGFloat] {
        let view = GhostContentView(frame: NSRect(origin: .zero, size: size))
        view.metrics = GhostTextMetrics(font: .systemFont(ofSize: 20, weight: .heavy))
        view.lines = [("MMMM", 0)]
        view.textColor = textColor
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
        rep.bitmapData?.update(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
        view.cacheDisplay(in: view.bounds, to: rep)

        var best: [CGFloat] = [0, 0, 0, 0]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > best[3] else { continue }
                best = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
            }
        }
        return best
    }

    func testHostColourIsDrawnAtGhostAlpha() {
        let ink = strongestInk(textColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertGreaterThan(ink[3], 0.3)
        XCTAssertLessThanOrEqual(ink[3], GhostTextRenderer.ghostAlpha + 0.02)
        XCTAssertGreaterThan(ink[0], 0.9, "red host text draws red ghost text")
        XCTAssertLessThan(ink[1], 0.1)
        XCTAssertLessThan(ink[2], 0.1)
    }

    func testNoHostColourKeepsTheDesignToken() {
        let token = strongestInk(textColor: nil)
        let red = strongestInk(textColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertGreaterThan(token[3], 0.3)
        XCTAssertNotEqual(token, red, "without a host colour the token, not red, is drawn")
    }

    func testRendererPassesTheGeometryColourToTheView() {
        struct Fixed: InlineCaretGeometryProvider {
            let geometry: CaretGeometry
            func caretGeometry() -> CaretGeometry? { geometry }
        }
        let color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let geometry = CaretGeometry(
            caretRect: CGRect(x: 100, y: 200, width: 0, height: 20),
            fieldBounds: CGRect(x: 50, y: 150, width: 400, height: 200),
            metrics: GhostTextMetrics(font: .monospacedSystemFont(ofSize: 12, weight: .regular)),
            textColor: color
        )
        let renderer = GhostTextRenderer(geometryProvider: Fixed(geometry: geometry), caretRetry: .none)
        renderer.show(candidate: "hello")
        XCTAssertEqual(renderer.ghostContent.textColor, color)

        var plain = geometry
        plain.textColor = nil
        let other = GhostTextRenderer(geometryProvider: Fixed(geometry: plain), caretRetry: .none)
        other.show(candidate: "hello")
        XCTAssertNil(other.ghostContent.textColor)
        renderer.clear()
        other.clear()
    }
}
