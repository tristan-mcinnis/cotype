import Foundation

/// Testable decision for how the in-app Sparkle updater should start up, so the
/// app never schedules or performs an automatic update check against the user's
/// stored preference.
public enum SparkleUpdaterPolicy: Equatable, Sendable {

    /// No release feed is configured (a dev/personal build) — Sparkle stays inert.
    case notConfigured

    /// A feed is configured AND the user enabled automatic checks — the updater
    /// may schedule and perform automatic checks.
    case enabledAutomatic

    /// A feed is configured but the user disabled automatic checks — the updater
    /// is available for manual "Check for Updates" only, and must NOT perform a
    /// launch-time check.
    case enabledManualOnly

    /// The startup policy for a given bundle configuration.
    ///
    /// - Parameters:
    ///   - feedConfigured: whether the release build ships `SUFeedURL`/`SUPublicEDKey`.
    ///   - storedAutoCheck: the user's persisted "automatically check for updates" toggle.
    public static func resolve(feedConfigured: Bool, storedAutoCheck: Bool) -> SparkleUpdaterPolicy {
        guard feedConfigured else { return .notConfigured }
        return storedAutoCheck ? .enabledAutomatic : .enabledManualOnly
    }
}

extension SparkleUpdaterPolicy {
    /// True when the updater may schedule/perform automatic checks. A manual-only
    /// or not-configured build must never check automatically.
    public var mayAutoCheck: Bool {
        self == .enabledAutomatic
    }
}

/// One ordered startup step the in-app Sparkle updater must perform, so the
/// user's automatic-check preference is applied BEFORE the updater is started
/// (a privacy race if `startingUpdater: true` schedules a check before the
/// preference reaches the updater) and no automatic check is forced while it is
/// off. The step order is deterministic and testable.
public enum SparkleStartupStep: Equatable, Sendable {
    /// Set the privacy-preserving defaults BEFORE starting the updater: never send
    /// a system profile to the feed (sendsSystemProfile=false) and never download
    /// an update until the user approves it in Sparkle's UI
    /// (automaticallyDownloadsUpdates=false).
    case applyPrivacyDefaults
    /// Set `SPUUpdater.automaticallyChecksForUpdates` BEFORE starting the updater.
    case applyAutomaticCheck(Bool)
    /// Start the updater (`startUpdater()`). Once started with auto-check OFF,
    /// no automatic check is scheduled; with auto-check ON Sparkle schedules its
    /// own launch/interval checks, so no separate explicit background check is
    /// added (avoids a duplicate immediate check).
    case startUpdater
}

/// Decides whether a bundle carries a complete, safe Sparkle update config.
/// The app is only wired into the updater when BOTH SUFeedURL and a nonempty
/// SUPublicEDKey are present — a partial/misconfigured release (e.g. a feed URL
/// with no public key) stays inert rather than starting an unusable updater.
public enum SparkleUpdateConfig {
    public static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        guard let feed = feedURL, !feed.isEmpty, let pub = publicKey, !pub.isEmpty else {
            return false
        }
        return true
    }
}

/// Computes the ordered startup steps for a given feed configuration and stored
/// auto-check preference, so the controller can apply them in the safe order and
/// the ordering is verifiable in isolation.
public enum SparkleStartup {
    public static func orderedSteps(feedConfigured: Bool, storedAutoCheck: Bool) -> [SparkleStartupStep] {
        switch SparkleUpdaterPolicy.resolve(feedConfigured: feedConfigured, storedAutoCheck: storedAutoCheck) {
        case .notConfigured:
            return []
        case .enabledAutomatic:
            // Privacy defaults and the auto-check preference come BEFORE start() so
            // the updater never sends a profile / auto-downloads without approval.
            return [.applyPrivacyDefaults, .applyAutomaticCheck(true), .startUpdater]
        case .enabledManualOnly:
            return [.applyPrivacyDefaults, .applyAutomaticCheck(false), .startUpdater]
        }
    }
}
