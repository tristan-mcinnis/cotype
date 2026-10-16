import Foundation

/// Ensures personal data files are owner-only (0600). Used by the persistence
/// stores for files that may contain user content (per-app overrides and system
/// prompts, completion samples, privacy config). Best-effort: failures are
/// swallowed (the write itself already succeeded). It never calls back into a
/// store, so it is safe to invoke while holding a store's lock.
enum SecurePermissions {
    /// Restrict `url` to owner-only read/write.
    static func apply(to url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
}
