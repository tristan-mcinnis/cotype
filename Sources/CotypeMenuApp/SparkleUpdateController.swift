import AppKit
import Combine
import Sparkle
import CotypeCore

/// Drives auto-updates through Sparkle 2.
///
/// Sparkle is only spun up when the bundle is a **release candidate** that ships
/// `SUFeedURL` + `SUPublicEDKey` in Info.plist. A dev/personal build has neither,
/// so `controller == nil` and Sparkle stays inert (no network, no updater).
///
/// Startup ordering is deliberate and avoids a privacy race: the updater is
/// constructed with `startingUpdater: false`, the user's stored automatic-check
/// preference is applied FIRST, and only then is `startUpdater()` called. With
/// automatic checks OFF (manual-only policy) the updater is never started into a
/// state that schedules a check, and no explicit background check is issued.
@MainActor
final class SparkleUpdateController: ObservableObject {

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            defaults.set(automaticallyChecksForUpdates, forKey: Self.autoCheckKey)
        }
    }

    private let controller: SPUStandardUpdaterController?
    private let defaults: UserDefaults

    static let autoCheckKey = "automaticallyChecksForUpdates"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A complete, safe update config requires BOTH the feed URL and a nonempty
        // Ed25519 public key. A partial/misconfigured bundle stays inert rather
        // than starting an updater that cannot verify updates.
        let feedConfigured = SparkleUpdateConfig.isConfigured(
            feedURL: Bundle.main.infoDictionary?["SUFeedURL"] as? String,
            publicKey: Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
        )
        let auto = defaults.bool(forKey: Self.autoCheckKey)
        self.automaticallyChecksForUpdates = auto

        let steps = SparkleStartup.orderedSteps(feedConfigured: feedConfigured, storedAutoCheck: auto)
        guard !steps.isEmpty else {
            self.controller = nil   // no feed: never initialize Sparkle
            return
        }
        // Construct WITHOUT starting the updater so we can apply the preference
        // first (Sparkle's built-in auto-check scheduling must not run before the
        // user's opt-out is in place).
        let c = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = c
        for step in steps {
            switch step {
            case .applyPrivacyDefaults:
                // Never send a system profile to the feed, and never download an
                // update until the user approves it in Sparkle's UI. The app exposes
                // no control for these; they are strictly privacy-preserving.
                c.updater.sendsSystemProfile = false
                c.updater.automaticallyDownloadsUpdates = false
            case .applyAutomaticCheck(let enabled):
                c.updater.automaticallyChecksForUpdates = enabled
            case .startUpdater:
                try? c.updater.start()
            }
        }
        // No `checkForUpdatesInBackground()` here: when automatic checks are on,
        // startUpdater() schedules Sparkle's own launch/interval check (no
        // duplicate immediate check); when they are off, we must not check at all.
    }

    /// True when Sparkle is wired (a release candidate with a configured feed).
    var isEnabled: Bool { controller != nil }

    /// Trigger a user-initiated "Check for Updates" (Sparkle shows its own UI).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Persist the user's auto-check preference and drive Sparkle's scheduler.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
    }
}
