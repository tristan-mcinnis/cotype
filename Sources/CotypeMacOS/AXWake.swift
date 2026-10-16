import AppKit
import ApplicationServices
import CotypeCore

/// Accessibility preparation every reference app does before reading AX.
///
/// 1. A 50 ms messaging timeout (TabType, cotabby). Without it a stalled host
///    app blocks each AX call for the system default of about 6 s, which
///    freezes Cotype's main thread and, through the event taps, typing.
/// 2. Waking Chromium/Electron web accessibility. Chromium builds its web AX
///    tree only when an assistive client asks, so without this the focused
///    element is a window-sized group with no text, selection, or caret bounds
///    (all three reference apps; cotabby uses `AXManualAccessibility` because
///    `AXEnhancedUserInterface` can upset window managers).
@MainActor
enum AXWake {
    static let messagingTimeout: Float = 0.05

    private static var didSetSystemWideTimeout = false
    private static var wokenPIDs: Set<pid_t> = []

    /// Prepare the frontmost app's AX element for reads. Cheap after the first
    /// call per pid.
    static func prepare(_ app: NSRunningApplication) {
        if !didSetSystemWideTimeout {
            // The system-wide element's timeout becomes the default for every
            // element this process creates afterwards.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
            didSetSystemWideTimeout = true
        }
        let pid = app.processIdentifier
        guard !wokenPIDs.contains(pid) else { return }
        wokenPIDs.insert(pid)

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        let bundleID = app.bundleIdentifier ?? ""
        guard AppCompatibility.needsWebAccessibilityWake(bundleID: bundleID, bundleURL: app.bundleURL) else {
            return
        }
        let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual != .success {
            // Older Chromium builds only honour the VoiceOver-era attribute.
            // Chromium sometimes applies it while still reporting an error.
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        CotypeLog.loop.info("woke web accessibility for \(bundleID, privacy: .public) (manual=\(manual == .success, privacy: .public))")
    }

    /// Electron editors let their web AX tree fall asleep again (cotabby saw
    /// this in VS Code), so each activation re-asserts the wake.
    static func noteActivated(_ app: NSRunningApplication?) {
        guard let app else { return }
        wokenPIDs.remove(app.processIdentifier)
        prepare(app)
    }
}
