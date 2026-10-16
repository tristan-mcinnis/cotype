import Foundation

/// Per-application overrides that tweak the completion pipeline for a specific
/// app (e.g. a different model or system prompt in Xcode than in Mail).
///
/// Every field is optional: a `nil` field means "inherit the default", so an
/// override can change just one supported behavior without re-declaring the
/// rest. Model and sampler settings are global because Cotype keeps one shared
/// in-memory model rather than loading multi-gigabyte per-app copies.
public struct AppOverride: Codable, Equatable, Sendable {
    /// `nil` = inherit; `false` = completions disabled for this app.
    public var enabled: Bool?
    /// Override the system prompt.
    public var systemPrompt: String?

    public init(enabled: Bool? = nil, systemPrompt: String? = nil) {
        self.enabled = enabled
        self.systemPrompt = systemPrompt
    }

    /// Combine this override over a base value. Non-nil fields win; nil fields
    /// fall through to the base.
    public func merged(into base: AppOverride) -> AppOverride {
        AppOverride(
            enabled: enabled ?? base.enabled,
            systemPrompt: systemPrompt ?? base.systemPrompt
        )
    }
}

/// Persists `AppOverride` values keyed by bundle identifier.
///
/// The special key `AppOverridesStore.defaultKey` ("default") holds global
/// fallbacks that every app inherits from. Storage is a JSON file (injectable
/// for tests) guarded by a serial queue, so it is safe to call from any thread.
public final class AppOverridesStore: @unchecked Sendable {
    /// Bundle-identifier key that holds the global defaults.
    public static let defaultKey = "default"

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.cotype.app-overrides")
    private var overrides: [String: AppOverride]

    /// - Parameter fileURL: where to persist overrides. Defaults to
    ///   `~/Library/Application Support/Cotype/app-overrides.json`.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: AppOverride].self, from: data) {
            self.overrides = decoded
        } else {
            self.overrides = [:]
        }
        // Remediate an existing file that predates the owner-only policy.
        SecurePermissions.apply(to: self.fileURL)
    }

    /// The effective override for a bundle ID: the app's own override merged
    /// over the global `default` override.
    public func override(for bundleID: String) -> AppOverride {
        queue.sync {
            let base = overrides[Self.defaultKey] ?? AppOverride()
            return (overrides[bundleID] ?? AppOverride()).merged(into: base)
        }
    }

    /// The raw (unmerged) override for a key, if one was set.
    public func rawOverride(for key: String) -> AppOverride? {
        queue.sync { overrides[key] }
    }

    /// Every override key currently persisted (including the `default` key when
    /// set). Exposed so the Apps UI can list apps that have an override even
    /// when they have no recorded samples, without reading the JSON file itself.
    public func allKeys() -> Set<String> {
        queue.sync { Set(overrides.keys) }
    }

    /// Whether an override exists for a key (vs. inheriting the default).
    public func hasOverride(for key: String) -> Bool {
        queue.sync { overrides[key] != nil }
    }

    /// Set (or replace) the override for a bundle ID or the default key.
    public func setOverride(_ override: AppOverride, for key: String) {
        queue.sync {
            overrides[key] = override
            persist()
        }
    }

    /// Remove the override for a key, reverting it to inheritance.
    public func removeOverride(for key: String) {
        queue.sync {
            overrides.removeValue(forKey: key)
            persist()
        }
    }

    /// Remove all overrides.
    public func clear() {
        queue.sync {
            overrides.removeAll()
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            SecurePermissions.apply(to: fileURL)
        } catch {
            // Overrides are non-critical and non-blocking; failures are swallowed.
        }
    }

    public static func defaultFileURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cotype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-overrides.json")
    }
}
