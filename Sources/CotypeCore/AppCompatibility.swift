import Foundation

/// Per-app facts that change how Cotype treats the frontmost app.
///
/// Mirrors the policy tables in TabType (`AppPolicyStore`), KeyType
/// (`DefaultOverrides`), and cotabby (`TerminalAppDetector`,
/// `BrowserAppDetector`): all three turn terminals off by default and wake the
/// Chromium/Electron accessibility tree before reading it.
public enum AppCompatibility {

    /// Standalone terminals. Their AX value is the whole scrollback, they expose
    /// no caret bounds (Ghostty has no `AXBoundsForRange`), and Tab belongs to
    /// the shell. Off unless the user enables the app in Apps settings.
    public static let terminals: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.raphaelamorim.rio",
    ]

    /// Apps where Tab already has its own job, so Cotype stays out entirely.
    /// Quick Launch uses Tab in its prompt field.
    public static let tabOwners: Set<String> = [
        "com.tristanmcinnis.quick-launch",
    ]

    /// Chromium-family browsers whose web content builds its AX tree lazily.
    public static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "net.imput.helium",
    ]

    /// Browsers whose focused window can identify a website. The Chromium set
    /// builds its AX tree lazily; Safari and Firefox expose the document URL on
    /// the focused window through the same standard attribute.
    public static let browsers: Set<String> = chromiumBrowsers.union([
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
    ])

    public static func isTerminal(_ bundleID: String) -> Bool {
        terminals.contains(bundleID)
    }

    public static func isBrowser(_ bundleID: String) -> Bool {
        browsers.contains(bundleID)
    }

    /// Whether completions run in this app, given the user's explicit override
    /// (`nil` = no override). Terminals need an explicit opt-in.
    public static func isEnabled(bundleID: String, override: Bool?) -> Bool {
        if let override { return override }
        return !isTerminal(bundleID) && !tabOwners.contains(bundleID)
    }

    /// Whether the app is Electron, by the framework KeyType's classifier looks
    /// for inside the bundle. Cached per bundle path; the scan is one stat call.
    public static func isElectron(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        cacheLock.lock()
        if let cached = electronCache[bundleURL.path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let result = FileManager.default.fileExists(atPath: framework.path)
        cacheLock.lock()
        electronCache[bundleURL.path] = result
        cacheLock.unlock()
        return result
    }

    /// Whether the app's web content needs its accessibility tree woken.
    public static func needsWebAccessibilityWake(bundleID: String, bundleURL: URL?) -> Bool {
        chromiumBrowsers.contains(bundleID) || isElectron(bundleURL: bundleURL)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var electronCache: [String: Bool] = [:]
}
