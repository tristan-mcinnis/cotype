import XCTest
import AppKit
@testable import CotypeMacOS

/// The Accessibility font payload comes in two shapes, and reading only one of
/// them silently drew the ghost in the fallback face. These tests pin both shapes
/// plus the decoding rules that keep a bad value from becoming a wild line box.
final class AXFontDecodingTests: XCTestCase {

    private let menlo = NSFont(name: "Menlo-Regular", size: 12)!

    private func cocoa(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font]
    }

    private func axFont(_ fields: [String: Any]) -> [NSAttributedString.Key: Any] {
        [NSAttributedString.Key(AXFontDecoder.axFontAttributeName): fields]
    }

    // MARK: - Cocoa representation

    func testCocoaNSFontIsUsedAsIs() {
        let decoded = AXFontDecoder.font(fromAttributes: cocoa(menlo))
        XCTAssertEqual(decoded?.fontName, "Menlo-Regular")
        XCTAssertEqual(decoded?.pointSize, 12)
    }

    func testCocoaFontWithAnAbsurdSizeIsRejected() {
        // A 5000 pt editor font is a corrupt or unit-confused value, not text: it
        // would produce a line box taller than any field.
        XCTAssertNil(AXFontDecoder.font(fromAttributes: cocoa(NSFont.systemFont(ofSize: 5000))))
    }

    // MARK: - Accessibility AXFont dictionary

    func testAXFontDictionaryIsDecoded() {
        let decoded = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "Menlo-Regular",
            AXFontDecoder.sizeKey: 13,
        ]))
        XCTAssertEqual(decoded?.fontName, "Menlo-Regular")
        XCTAssertEqual(decoded?.pointSize, 13)
    }

    /// Some hosts put the same dictionary under the Cocoa `.font` key; the value
    /// is not an `NSFont`, so a single `as? NSFont` check would lose it.
    func testAXFontDictionaryUnderTheFontKeyIsDecoded() {
        let decoded = AXFontDecoder.font(fromAttributes: [
            .font: [AXFontDecoder.nameKey: "Menlo-Regular", AXFontDecoder.sizeKey: 12],
        ])
        XCTAssertEqual(decoded?.fontName, "Menlo-Regular")
        XCTAssertEqual(decoded?.pointSize, 12)
    }

    func testFlattenedAXFontKeysOnTheRunAreDecoded() {
        let decoded = AXFontDecoder.font(fromAttributes: [
            NSAttributedString.Key(AXFontDecoder.nameKey): "Menlo-Regular",
            NSAttributedString.Key(AXFontDecoder.sizeKey): 11,
        ])
        XCTAssertEqual(decoded?.fontName, "Menlo-Regular")
        XCTAssertEqual(decoded?.pointSize, 11)
    }

    func testBridgedNSDictionaryIsDecoded() {
        let payload = NSDictionary(dictionary: [
            AXFontDecoder.nameKey: "Menlo-Regular",
            AXFontDecoder.sizeKey: 12,
        ])
        let decoded = AXFontDecoder.font(fromFontValue: payload)
        XCTAssertEqual(decoded?.fontName, "Menlo-Regular")
    }

    func testFamilyIsUsedWhenTheNamedFaceIsUnavailable() {
        let decoded = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "No-Such-Face-9F2",
            AXFontDecoder.familyKey: "Helvetica",
            AXFontDecoder.sizeKey: 12,
        ]))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.pointSize, 12)
        XCTAssertEqual(decoded?.familyName, "Helvetica")
    }

    /// An unknown face must not become a monospaced fallback: the size is the one
    /// fact the host reported and the face is unknown, so the system text face at
    /// that size is the closest honest answer.
    func testUnknownFaceKeepsTheReportedSizeAndStaysProportional() {
        let decoded = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "No-Such-Face-9F2",
            AXFontDecoder.sizeKey: 15,
        ]))
        XCTAssertEqual(decoded?.pointSize, 15)
        XCTAssertEqual(decoded?.isFixedPitch, false)
    }

    func testBoldAndItalicTraitsAreApplied() {
        let bold = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "Menlo-Regular",
            AXFontDecoder.sizeKey: 12,
            AXFontDecoder.boldKey: true,
        ]))
        XCTAssertEqual(bold?.pointSize, 12)
        XCTAssertTrue(
            NSFontManager.shared.traits(of: bold ?? menlo).contains(.boldFontMask),
            "an AXFontBold flag must produce a bold face"
        )

        let italic = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "Menlo-Regular",
            AXFontDecoder.sizeKey: 12,
            AXFontDecoder.italicKey: true,
        ]))
        XCTAssertTrue(
            NSFontManager.shared.traits(of: italic ?? menlo).contains(.italicFontMask),
            "an AXFontItalic flag must produce an italic face"
        )
    }

    func testAnAlreadyBoldFaceIsNotDoubleConverted() {
        let decoded = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "Menlo-Bold",
            AXFontDecoder.sizeKey: 12,
            AXFontDecoder.boldKey: true,
        ]))
        XCTAssertEqual(decoded?.fontName, "Menlo-Bold")
        XCTAssertEqual(decoded?.pointSize, 12)
    }

    // MARK: - Size validation

    func testSizesOutsideThePlausibleRangeAreRejected() {
        for size: Any in [0, -12, 3.9, 321, Double.nan, Double.infinity, true, "abc", [12]] {
            XCTAssertNil(
                AXFontDecoder.font(fromAttributes: axFont([
                    AXFontDecoder.nameKey: "Menlo-Regular",
                    AXFontDecoder.sizeKey: size,
                ])),
                "size \(size) must not decode to a font"
            )
        }
    }

    func testStringifiedSizeIsAccepted() {
        let decoded = AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "Menlo-Regular",
            AXFontDecoder.sizeKey: "12.5",
        ]))
        XCTAssertEqual(decoded?.pointSize, 12.5)
    }

    func testDictionaryWithoutASizeIsRejected() {
        XCTAssertNil(AXFontDecoder.font(fromAttributes: axFont([
            AXFontDecoder.nameKey: "Menlo-Regular",
        ])))
        XCTAssertNil(AXFontDecoder.font(fromAttributes: axFont([:])))
    }

    // MARK: - Attributed strings

    func testAttributedStringUsesItsFirstRunFont() {
        let attributed = NSAttributedString(string: "x", attributes: cocoa(menlo))
        XCTAssertEqual(AXFontDecoder.font(from: attributed)?.fontName, "Menlo-Regular")
    }

    func testEmptyAttributedStringHasNoFont() {
        XCTAssertNil(AXFontDecoder.font(from: NSAttributedString(string: "")))
    }

    func testAttributedStringWithoutAFontReturnsNil() {
        let attributed = NSAttributedString(string: "x", attributes: [
            .foregroundColor: NSColor.labelColor,
        ])
        XCTAssertNil(AXFontDecoder.font(from: attributed))
    }
}
