import AppKit

// Menu-bar entry point. The app is `.accessory`: it has no Dock icon and never
// takes over the foreground unless the settings window is explicitly opened.
// Top-level code runs on the main thread; tell the compiler we are on the main
// actor so the @MainActor AppDelegate can be constructed without implicit async.
MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Offscreen render proof: draw the Slate surfaces to PNGs and exit without
    // ever showing a window. Used to compare the built UI against the mockup.
    if let index = CommandLine.arguments.firstIndex(of: "--render-proof"),
       CommandLine.arguments.count > index + 1 {
        app.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        for url in RenderProof.run(into: directory) {
            print(url.path)
        }
        exit(0)
    }

    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
