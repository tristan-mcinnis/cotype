import Foundation

/// Migration handling for the model-catalog change from the base
/// `gemma-4-E2B-i1-Q4_K_M.gguf` to the instruction-tuned
/// `gemma-4-E2B-it-Q4_K_M.gguf`.
///
/// The pinned catalog changed its managed filename, so existing users' verified
/// base model is now orphaned. Without a cleanup, downloading the IT model would
/// leave ~6.6 GB of weights on disk. These helpers:
///   - remove the legacy base artifact **only after** the current model is fully
///     downloaded and SHA-verified (the caller must be in a post-verification
///     state — never before an install succeeds),
///   - remove only the exact legacy managed filename and its obsolete marker,
///     never arbitrary files in the directory,
///   - report a legacy-only machine so Setup treats it as "needs the IT
///     upgrade", not a fresh no-model state.
public enum ModelMigration {

    /// The legacy base-model managed filename installed by the previous pin.
    public static let legacyManagedFilename = "gemma-4-E2B-i1-Q4_K_M.gguf"

    /// The obsolete marker key the previous pin wrote (it used the legacy
    /// filename in its `verifiedKey`).
    private static var legacyMarkerKey: String {
        "model.verified.sha.\(legacyManagedFilename)"
    }

    /// True when the legacy base model is present in the managed directory. This
    /// alone does not mean "upgrade required" — the caller combines it with
    /// whether the current model is installed.
    public static func hasLegacyArtifact(in directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(legacyManagedFilename).path)
    }

    /// Remove the legacy base model file and its obsolete marker (idempotent).
    ///
    /// Safety invariants:
    ///  - Must only be called AFTER the current model is fully downloaded and
    ///    SHA-verified (caller is in a post-verification state).
    ///  - Deletes exactly `legacyManagedFilename`, never any other file.
    public static func cleanupLegacyArtifact(
        in directory: URL,
        defaults: UserDefaults,
        fileManager: FileManager = .default
    ) {
        let legacyURL = directory.appendingPathComponent(legacyManagedFilename)
        if fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
        defaults.removeObject(forKey: legacyMarkerKey)
    }
}
