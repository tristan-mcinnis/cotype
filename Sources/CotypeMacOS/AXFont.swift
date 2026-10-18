import AppKit
import Foundation

/// Decodes the font a host attaches to an Accessibility attributed string.
///
/// Hosts disagree about how to report a font, and reading only one shape is a
/// silent, visible failure. Native AppKit editors answer `kAXAttributedStringForRange`
/// with a Cocoa `.font` attribute holding an `NSFont`. The standard Accessibility
/// representation is an `AXFont` **dictionary** (`AXFontName`, `AXFontFamily`,
/// `AXFontSize`, `AXFontBold`, `AXFontItalic`) under the `AXFont` attribute key,
/// which is exactly what many editors return. Reading only `.font` missed those,
/// fell through to a fixed monospaced fallback, and drew the ghost in a face one
/// em wider than the document's text.
///
/// The decoder keeps no text: it reads font attributes only, and its fallbacks
/// preserve the reported size and traits so an unknown family still yields a
/// proportional font at the right size instead of a monospaced guess.
enum AXFontDecoder {

    /// The attributed-string attribute name Accessibility uses for its font
    /// dictionary. It is a plain string, not one of the `NSAttributedString.Key`
    /// constants.
    static let axFontAttributeName = "AXFont"

    static let nameKey = "AXFontName"
    static let familyKey = "AXFontFamily"
    static let sizeKey = "AXFontSize"
    static let boldKey = "AXFontBold"
    static let italicKey = "AXFontItalic"

    /// Every key a font dictionary (or a flattened run) can carry.
    static let dictionaryKeys = [nameKey, familyKey, sizeKey, boldKey, italicKey]

    /// A point size outside this range is not an editor font. `AXFontSize` is in
    /// points, so zero, negative, unit-confused (px x2) or corrupt values are
    /// rejected rather than turned into a wild line box.
    static let pointSizeRange: ClosedRange<CGFloat> = 4...320

    // MARK: - Entry points

    /// The first font the attributed string declares, or nil when it declares none.
    static func font(from attributed: NSAttributedString) -> NSFont? {
        guard attributed.length > 0 else { return nil }
        return font(fromAttributes: attributed.attributes(at: 0, effectiveRange: nil))
    }

    /// Decode one run's attributes. Cocoa `.font` wins when it holds an `NSFont`;
    /// the Accessibility dictionary is decoded from name, family, size and traits,
    /// whether it sits under `.font`, under `AXFont`, or flattened onto the run.
    static func font(fromAttributes attributes: [NSAttributedString.Key: Any]) -> NSFont? {
        if let font = font(fromFontValue: attributes[.font]) { return font }

        // The Accessibility font dictionary, under its own attribute name.
        if let font = font(fromFontValue: attributes[NSAttributedString.Key(axFontAttributeName)]) {
            return font
        }

        // Some hosts flatten AXFontName / AXFontSize (and the trait flags) onto
        // the run instead of nesting them in a dictionary.
        var flattened: [String: Any] = [:]
        for (key, value) in attributes where dictionaryKeys.contains(key.rawValue) {
            flattened[key.rawValue] = value
        }
        return flattened.isEmpty ? nil : font(fromAXFontDictionary: flattened)
    }

    /// A value that may already be an `NSFont`, or may be an Accessibility font
    /// dictionary bridged from `CFDictionary`.
    static func font(fromFontValue value: Any?) -> NSFont? {
        if let cocoa = cocoaFont(value) { return cocoa }
        return font(fromAXFontDictionary: value)
    }

    // MARK: - Cocoa NSFont

    static func cocoaFont(_ value: Any?) -> NSFont? {
        guard let font = value as? NSFont else { return nil }
        guard validPointSize(font.pointSize) else { return nil }
        return font
    }

    // MARK: - AX font dictionary

    /// Decode the standard Accessibility font dictionary. Every field is optional
    /// except a validated size; a name that no longer exists falls back to the
    /// family, then to the system font at the reported size and weight.
    static func font(fromAXFontDictionary value: Any?) -> NSFont? {
        guard let dictionary = stringKeyedDictionary(value),
              let size = pointSize(dictionary[sizeKey])
        else { return nil }

        let name = nonEmptyString(dictionary[nameKey])
        let family = nonEmptyString(dictionary[familyKey])
        let bold = flag(dictionary[boldKey])
        let italic = flag(dictionary[italicKey])
        return font(name: name, family: family, size: size, bold: bold, italic: italic)
    }

    /// Build the closest real font to a reported face. Never returns a font at a
    /// different size, and never silently swaps to a fixed-pitch face.
    static func font(
        name: String?,
        family: String?,
        size: CGFloat,
        bold: Bool,
        italic: Bool
    ) -> NSFont? {
        guard validPointSize(size) else { return nil }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }

        if let name, let named = NSFont(name: name, size: size) {
            return applying(traits: traits, to: named)
        }

        let manager = NSFontManager.shared
        if let family,
           let familyFont = manager.font(
               withFamily: family,
               traits: traits,
               weight: bold ? 9 : 5,
               size: size
           ) {
            return familyFont
        }

        // Unknown face: keep the size and the traits, not the family.
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return applying(traits: traits, to: base)
    }

    /// Add the reported traits when the face itself does not already carry them.
    /// A named bold face (`Helvetica-Bold`) is returned untouched.
    private static func applying(traits: NSFontTraitMask, to font: NSFont) -> NSFont {
        guard !traits.isEmpty else { return font }
        let manager = NSFontManager.shared
        let existing = manager.traits(of: font)
        var result = font
        if traits.contains(.boldFontMask), !existing.contains(.boldFontMask) {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask), !existing.contains(.italicFontMask) {
            result = manager.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    // MARK: - Value decoding

    /// A validated, finite point size, or nil. Zero, negatives, NaN, infinities
    /// and values outside `pointSizeRange` are rejected: they would otherwise
    /// produce a zero-height or absurd line box and move the ghost off the caret.
    static func pointSize(_ value: Any?) -> CGFloat? {
        let size: CGFloat?
        switch value {
        case let number as NSNumber:
            // A CFBoolean also bridges to NSNumber; it is not a size.
            size = CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : CGFloat(number.doubleValue)
        case let double as Double:
            size = CGFloat(double)
        case let integer as Int:
            size = CGFloat(integer)
        case let string as String:
            // Some hosts stringify the size in the dictionary.
            size = Double(string).map { CGFloat($0) }
        default:
            size = nil
        }
        guard let size, validPointSize(size) else { return nil }
        return size
    }

    static func validPointSize(_ size: CGFloat) -> Bool {
        size.isFinite && pointSizeRange.contains(size)
    }

    /// A truthy flag from a CFBoolean/NSNumber/NSString, defaulting to false.
    static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Bridge an `NSDictionary`/`CFDictionary` payload to `[String: Any]`. Keys
    /// that are not strings are ignored rather than force-cast.
    static func stringKeyedDictionary(_ value: Any?) -> [String: Any]? {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary
        case let dictionary as NSDictionary:
            var out: [String: Any] = [:]
            for (key, element) in dictionary {
                guard let key = key as? String else { continue }
                out[key] = element
            }
            return out.isEmpty ? nil : out
        default:
            return nil
        }
    }
}
