import Foundation
import Combine

/// UI-facing coordinator for acquiring, monitoring, and managing the installed
/// model. Wraps a `ModelInstalling` collaborator and publishes observable state
/// for SwiftUI (progress, speed, phase, and the result of the last attempt).
///
/// This lives in `CotypeCore` (not the menu app) so its state machine and
/// cancellation/resume/removal behavior are unit-testable with a fake installer.
/// It has no AppKit/SwiftUI dependency — only Combine + Foundation.
///
/// Responsibilities:
///  - Drive an install, tracking progress, running speed, and remaining size.
///  - Persist a "verified" marker (the expected SHA-256) so a completed download
///    is recognized without re-hashing the whole file on every launch.
///  - Pause (keep the partial file for resume), Resume, Retry, and Cancel
///    (abort and delete the partial file).
///  - Remove the installed model (used by Remove / Reinstall).
///  - After a successful install, invoke `onReady` so the caller can refresh the
///    engine and smoke-test it.
@MainActor
public final class ModelDownloadManager: ObservableObject {

    public enum State: Equatable, Sendable {
        case idle
        case downloading
        case verifying
        case paused
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var downloadedBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64?
    @Published public private(set) var speedBytesPerSecond: Double = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var isPaused: Bool = false

    /// Invoked on the main actor after a download verifies successfully. The
    /// owner should refresh the engine and run a smoke load here.
    public var onReady: (() -> Void)?

    public let spec: ModelSpec

    private let installer: any ModelInstalling
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    private var lastSampleTime: Date?
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0

    public init(
        spec: ModelSpec = .gemma4E2BIt,
        installer: any ModelInstalling = ModelInstaller(),
        defaults: UserDefaults = .standard
    ) {
        self.spec = spec
        self.installer = installer
        self.defaults = defaults
    }

    // MARK: - Derived state

    public var progressFraction: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(total))
    }

    public var remainingBytes: Int64? {
        guard let total = totalBytes, total > downloadedBytes else { return nil }
        return total - downloadedBytes
    }

    public var isBusy: Bool {
        state == .downloading || state == .verifying
    }

    /// True when the legacy base model is present but the current model is not
    /// installed. Setup should treat this as "requires the IT upgrade" rather
    /// than a fresh no-model state. The marker check is a UX cache only — it is
    /// not an integrity decision (see `isInstalled`).
    public var hasLegacyOnlyModel: Bool {
        ModelMigration.hasLegacyArtifact(in: spec.managedModelsDirectory) && !isInstalled
    }

    /// The verification marker is a **cache for UX metadata only** — it is NOT
    /// an integrity decision. It records the matching SHA plus the file's size
    /// and modification time so the UI can show an installed/verified state
    /// without hashing a multi-GB file on a SwiftUI property read. But a marker
    /// is bypassable: an attacker can tamper with the file and restore its
    /// size and mtime, and the marker still "passes". So the loadable/ready
    /// decision always comes from a real SHA-256 verification on launch/refresh
    /// (`refreshInstallationStatus` / `verifyExisting`), never from this cache.
    ///
    /// Callers must not gate loadability on this property; use `state == .ready`
    /// (which is only reached after a real verification succeeded).
    public var isInstalled: Bool {
        guard let marker = Self.loadMarker(for: spec, defaults: defaults) else { return false }
        guard marker.sha == spec.expectedSHA256 else { return false }
        guard FileManager.default.fileExists(atPath: spec.destinationURL.path) else { return false }
        let actualSize = Self.fileSize(spec.destinationURL)
        guard actualSize == marker.size, actualSize == spec.expectedSize else { return false }
        // Compare mtime within a small tolerance: filesystems / JSON round-tripping
        // are not bit-exact, and this is only a UX cache — the real integrity
        // decision is the SHA-256 verification on launch/refresh.
        return abs(Self.modifiedTime(spec.destinationURL) - marker.modified) < 2.0
    }

    /// True while a real SHA-256 verification is running off the main actor.
    public var isVerifying: Bool { state == .verifying }

    /// True only after a real SHA-256 verification succeeded and set the model
    /// ready. This is the ONLY state a caller may treat as "installed and
    /// verified" — never `isInstalled` (the size+mtime marker is a UX cache only
    /// and is bypassable by restoring a timestamp).
    public var isVerifiedNow: Bool { state == .ready }

    /// True when a model file is present at the managed path, regardless of
    /// whether it has been verified. Used for the "found; verification pending"
    /// UI state — never as a verified claim.
    public var filePresent: Bool {
        FileManager.default.fileExists(atPath: spec.destinationURL.path)
    }

    // MARK: - Control

    public func start() {
        guard !isBusy else { return }
        task?.cancel()
        // A user-initiated "Download & Install". The marker is NOT an integrity
        // decision: an exact-size file is re-verified (SHA-256, off the main
        // actor) before declaring it ready, and a hash mismatch triggers a fresh
        // download. A wrong-size file is an interrupted download and is resumed.
        guard FileManager.default.fileExists(atPath: spec.destinationURL.path) else {
            beginDownload()
            return
        }
        if Self.fileSize(spec.destinationURL) == spec.expectedSize {
            verifyExisting(startDownloadIfMissing: true)
        } else {
            beginDownload()
        }
    }

    /// Refresh the setup card on launch. Always runs a real SHA-256 verification
    /// off the main actor before declaring the model loadable; the marker is
    /// only a UX cache and is never trusted as an integrity check.
    public func refreshInstallationStatus() {
        guard !isBusy else { return }
        guard FileManager.default.fileExists(atPath: spec.destinationURL.path) else {
            if state == .ready { state = .idle }
            return
        }
        verifyExisting(startDownloadIfMissing: false)
    }

    private func verifyExisting(startDownloadIfMissing: Bool) {
        task?.cancel()
        state = .verifying
        isPaused = false
        lastError = nil
        let installer = self.installer
        let spec = spec
        task = Task { [weak self] in
            let verified = await Task.detached(priority: .utility) {
                installer.isInstalled(spec)
            }.value
            guard !Task.isCancelled, let self else { return }
            if verified {
                self.succeed()
            } else {
                // Real SHA-256 verification rejected the on-disk file. It must
                // not be loadable, and the cached marker must be dropped so the
                // UI never presents it as verified.
                self.defaults.removeObject(forKey: self.verifiedKey)
                if startDownloadIfMissing {
                    self.beginDownload()
                } else {
                    self.state = .idle
                }
            }
        }
    }

    private func beginDownload() {
        resetProgress()
        state = .downloading
        isPaused = false
        lastError = nil
        let installer = self.installer
        let spec = spec
        task = Task { [weak self] in
            do {
                for try await progress in installer.install(spec) {
                    try Task.checkCancellation()
                    self?.apply(progress)
                }
                self?.succeed()
            } catch is CancellationError {
                // A pause / cancel / superseded start stopped the download.
                // The controlling method already set the desired state.
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Abort an in-flight download but keep the partial file so a later `resume()`
    /// continues instead of restarting.
    public func pause() {
        guard isBusy else { return }
        task?.cancel()
        task = nil
        isPaused = true
        state = .paused
    }

    public func resume() {
        isPaused = false
        start()
    }

    /// Start again after a failure; resumes any partial file.
    public func retry() {
        isPaused = false
        start()
    }

    /// Abort and delete any partial download, returning to a clean idle state.
    public func cancel() {
        task?.cancel()
        task = nil
        isPaused = false
        try? FileManager.default.removeItem(at: spec.destinationURL)
        defaults.removeObject(forKey: verifiedKey)
        resetProgress()
        state = .idle
    }

    /// Remove the installed model (used by Remove / Reinstall).
    public func remove() {
        task?.cancel()
        task = nil
        isPaused = false
        try? FileManager.default.removeItem(at: spec.destinationURL)
        defaults.removeObject(forKey: verifiedKey)
        resetProgress()
        state = .idle
    }

    // MARK: - Progress handling

    private func apply(_ progress: ModelInstallProgress) {
        downloadedBytes = progress.downloadedBytes
        totalBytes = progress.totalBytes
        switch progress.phase {
        case .downloading: state = .downloading
        case .verifying: state = .verifying
        }
        sampleSpeed()
    }

    private func succeed() {
        // Persist a marker bound to the file's current size and modification
        // time, not just the expected SHA, so a later replacement is detected.
        let marker = VerifiedMarker(
            sha: spec.expectedSHA256,
            size: Self.fileSize(spec.destinationURL),
            modified: Self.modifiedTime(spec.destinationURL)
        )
        if let data = try? JSONEncoder().encode(marker),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: verifiedKey)
        }
        // We are post-verification (the installer verified the SHA before
        // finishing). Now it is safe to migrate away any orphaned legacy base
        // model from the previous pin. Cleanup is idempotent and deletes only
        // the exact legacy managed filename + its obsolete marker.
        ModelMigration.cleanupLegacyArtifact(
            in: spec.managedModelsDirectory,
            defaults: defaults
        )
        state = .ready
        isPaused = false
        onReady?()
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        state = .failed(message)
        isPaused = false
    }

    private func sampleSpeed() {
        let now = Date()
        defer { lastSampleTime = now; lastSampleBytes = downloadedBytes }
        guard let last = lastSampleTime else { return }
        let delta = now.timeIntervalSince(last)
        guard delta >= 0.2 else { return }
        let instantaneous = Double(downloadedBytes - lastSampleBytes) / delta
        smoothedSpeed = smoothedSpeed == 0 ? instantaneous : (smoothedSpeed * 0.7 + instantaneous * 0.3)
        speedBytesPerSecond = max(0, smoothedSpeed)
    }

    private func resetProgress() {
        downloadedBytes = 0
        totalBytes = nil
        speedBytesPerSecond = 0
        lastSampleTime = nil
        lastSampleBytes = 0
        smoothedSpeed = 0
    }

    private var verifiedKey: String {
        "model.verified.sha.\(spec.managedFilename)"
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func modifiedTime(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    }

    private static func loadMarker(for spec: ModelSpec, defaults: UserDefaults) -> VerifiedMarker? {
        let key = "model.verified.sha.\(spec.managedFilename)"
        guard let json = defaults.string(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VerifiedMarker.self, from: data)
    }
}

/// The persisted verification marker for an installed model. It records the
/// expected SHA-256 plus the file's exact size and modification time (in seconds
/// since the reference date) so a later replacement or touch invalidates the
/// marker and forces a real rehash, rather than trusting a stale marker.
private struct VerifiedMarker: Codable {
    var sha: String
    var size: Int64
    var modified: Double
}
