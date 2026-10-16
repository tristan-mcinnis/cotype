import AppKit
import SwiftUI
import CotypeCore
import CotypeMacOS

// Offscreen render proof. `cotype-menu --render-proof <dir>` draws the Slate
// surfaces into PNGs without ever putting a window on screen, so the design can
// be compared against the mockup in CI or by hand. Nothing here runs in the
// normal app path. The inline ghost overlay is not a Slate surface and is not
// drawn here.

@MainActor
enum RenderProof {

    /// Render every proof surface into `directory` and return the file paths.
    @discardableResult
    static func run(into directory: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let personalization = PersonalizationStore(
            fileURL: directory.appendingPathComponent("proof-personalization.json")
        )
        let overrides = AppOverridesStore()
        let engineManager = EngineManager()
        let completionController = CompletionController(
            engineManager: engineManager,
            personalization: personalization,
            overrides: overrides
        )
        let updater = SparkleUpdateController()

        var written: [URL] = []

        for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)), ("light", NSAppearance(named: .aqua))] {
            let settings = { (section: SettingsSection) in
                SettingsView(
                    engineManager: engineManager,
                    completionController: completionController,
                    personalization: personalization,
                    overrides: overrides,
                    updater: updater,
                    initialSection: section
                )
            }

            written.append(contentsOf: [
                write(
                    view: settings(.setup),
                    size: NSSize(width: 920, height: 620),
                    appearance: appearance,
                    to: directory.appendingPathComponent("settings-setup-\(name).png")
                ),
                write(
                    view: settings(.shortcuts),
                    size: NSSize(width: 920, height: 620),
                    appearance: appearance,
                    to: directory.appendingPathComponent("settings-shortcuts-\(name).png")
                ),
                write(
                    view: settings(.general),
                    size: NSSize(width: 920, height: 620),
                    appearance: appearance,
                    to: directory.appendingPathComponent("settings-general-\(name).png")
                ),
                write(
                    view: settings(.appSettings),
                    size: NSSize(width: 920, height: 620),
                    appearance: appearance,
                    to: directory.appendingPathComponent("settings-appsettings-\(name).png")
                ),
                write(
                    view: MenuBarPanelView(model: sampleMenuModel()),
                    size: NSSize(width: MenuBarPanelView.width + 2 * House.Spacing.md, height: 360),
                    appearance: appearance,
                    to: directory.appendingPathComponent("menubar-panel-\(name).png"),
                    fitToContent: true
                ),
            ].compactMap { $0 })
        }

        return written
    }

    /// The panel's live state, filled with the mockup's example values.
    static func sampleMenuModel() -> MenuPanelModel {
        let model = MenuPanelModel()
        model.completionsEnabled = true
        model.isReady = true
        model.statusLine = "gemma-it warm · Idle"
        model.actions = [
            PanelAction(id: "trigger", glyph: "sparkles", title: "Trigger completion", chord: "⌃."),
            PanelAction(id: "acceptWord", glyph: "arrow.turn.down.left", title: "Accept next word", chord: "⇥"),
            PanelAction(id: "acceptAll", glyph: "checkmark", title: "Accept all", chord: "⌥⇥"),
            PanelAction(id: "cancel", glyph: "xmark", title: "Cancel", chord: "esc"),
        ]
        model.moreActions = [
            PanelAction(id: "modelLifecycle", glyph: "shippingbox",
                            title: "Load/unload models in Local Models", isEnabled: false),
            PanelAction(id: "privacy", glyph: "hand.raised", title: "Open Privacy Settings…"),
        ]
        model.selection = 0
        return model
    }

    // MARK: - Rendering

    private static func write<V: View>(
        view: V,
        size: NSSize,
        appearance: NSAppearance?,
        to url: URL,
        fitToContent: Bool = false
    ) -> URL? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        if fitToContent {
            let fitted = hosting.fittingSize
            hosting.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(fitted.width, size.width), height: max(fitted.height, 1))
            )
        }
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI one runloop turn to commit its first layout pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        return capture(hosting, appearance: appearance, to: url)
    }

    /// Snapshot a view over the window ground, so a glass panel reads the way it
    /// does on screen instead of over transparency.
    private static func capture(_ view: NSView, appearance: NSAppearance?, to url: URL) -> URL? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) / view.bounds.width : 1
        guard let composite = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composite)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        let isDark = (appearance ?? NSAppearance.currentDrawing())
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            // A plain ground behind the shot: the window surface for opaque
            // views, a darker/lighter field for the floating panels.
            (isDark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        NSImage(size: view.bounds.size, flipped: false) { rect in
            rep.draw(in: rect)
            return true
        }.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = composite.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }
}
