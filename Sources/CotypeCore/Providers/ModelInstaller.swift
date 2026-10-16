import Foundation

// MARK: - Model install progress

/// Phases of acquiring a managed model.
public enum ModelInstallPhase: Equatable, Sendable {
    /// Bytes are transferring to disk.
    case downloading
    /// The file is on disk and being verified (size + SHA-256).
    case verifying
}

/// A snapshot of model acquisition, emitted as the download lands and during
/// verification. The final completion of the stream means the model was
/// downloaded AND verified. Any thrown error means it was not.
public struct ModelInstallProgress: Equatable, Sendable {
    public let phase: ModelInstallPhase
    public let downloadedBytes: Int64
    public let totalBytes: Int64?
    public let isFinal: Bool

    public init(phase: ModelInstallPhase, downloadedBytes: Int64, totalBytes: Int64?, isFinal: Bool = false) {
        self.phase = phase
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isFinal = isFinal
    }
}

// MARK: - ModelInstaller

/// Abstraction over model acquisition so the `ModelDownloadManager` (and tests)
/// can drive the install lifecycle without depending on the concrete installer
/// or a live network.
public protocol ModelInstalling {
    /// Acquires `spec`, emitting progress as it downloads and verifies. The
    /// stream finishes only after the file passes size and SHA-256 checks.
    func install(_ spec: ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error>
    /// Returns true when `spec`'s destination already exists and is fully verified.
    func isInstalled(_ spec: ModelSpec) -> Bool
}

/// Coordinates acquiring a `ModelSpec`: pre-flights disk space, streams the
/// download (resuming any existing partial file), then verifies the exact byte
/// size and SHA-256 before declaring success.
///
/// Design notes:
///  - It is `final` and takes its collaborators via the initializer so tests can
///    inject a stubbed `GGUFDownloader`, a `FileManager`, and a free-space
///    provider. `freeDiskSpace` is a closure rather than a live call so the
///    low-disk failure path is deterministic in tests.
///  - Cancelling the returned stream cancels the in-flight download but leaves a
///    partial file on disk, so a later retry resumes instead of restarting.
///  - On a checksum or size mismatch the destination file is removed ("fail
///    safely") so a corrupt file never survives to be loaded by the engine.
public final class ModelInstaller: ModelInstalling {

    private let downloader: GGUFDownloader
    private let fileManager: FileManager
    private let freeSpace: (URL) -> Int64

    public init(
        downloader: GGUFDownloader = GGUFDownloader(),
        fileManager: FileManager = .default,
        freeSpace: @escaping (URL) -> Int64 = { freeDiskSpace(at: $0) }
    ) {
        self.downloader = downloader
        self.fileManager = fileManager
        self.freeSpace = freeSpace
    }

    /// Acquires `spec`, emitting progress as it downloads and verifies. The
    /// stream finishes only after the file passes size and SHA-256 checks.
    public func install(_ spec: ModelSpec) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performInstall(spec) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// True if `spec` is already fully present, correctly sized, and matches the
    /// expected SHA-256 — without downloading.
    public func isInstalled(_ spec: ModelSpec) -> Bool {
        let url = spec.destinationURL
        guard fileManager.fileExists(atPath: url.path),
              fileSize(at: url) == spec.expectedSize,
              let digest = try? sha256OfFile(at: url) else {
            return false
        }
        return digest == spec.expectedSHA256
    }

    private func performInstall(
        _ spec: ModelSpec,
        onProgress: @escaping (ModelInstallProgress) -> Void
    ) async throws {
        let destination = spec.destinationURL

        try fileManager.createDirectory(at: spec.managedModelsDirectory, withIntermediateDirectories: true)

        // Pre-flight: refuse to start a multi-GB download that cannot possibly
        // fit. `diskRequirementBytes` already includes headroom, so we fail fast
        // and let the user free space instead of writing until the disk fills.
        try Task.checkCancellation()
        let available = freeSpace(destination)
        guard available >= spec.diskRequirementBytes else {
            throw ModelDownloadError.insufficientDiskSpace(required: spec.diskRequirementBytes, available: available)
        }

        // Stream the download (resuming any partial file). Cancelling the stream
        // cancels this loop and leaves the partial file in place for resume.
        for try await progress in downloader.download(spec.descriptor()) {
            try Task.checkCancellation()
            onProgress(ModelInstallProgress(
                phase: .downloading,
                downloadedBytes: progress.downloadedBytes,
                totalBytes: progress.totalBytes
            ))
        }

        // Verify size then SHA-256. On failure, delete the corrupt file so the
        // engine never loads it and the user gets a clean retry.
        try Task.checkCancellation()
        let actualSize = fileSize(at: destination)
        guard actualSize == spec.expectedSize else {
            try? fileManager.removeItem(at: destination)
            throw ModelDownloadError.sizeMismatch(expected: spec.expectedSize, actual: actualSize)
        }

        onProgress(ModelInstallProgress(
            phase: .verifying,
            downloadedBytes: actualSize,
            totalBytes: actualSize
        ))

        let digest: String
        do {
            digest = try sha256OfFile(at: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        try Task.checkCancellation()
        guard digest == spec.expectedSHA256 else {
            try? fileManager.removeItem(at: destination)
            throw ModelDownloadError.checksumMismatch(expected: spec.expectedSHA256, actual: digest)
        }

        onProgress(ModelInstallProgress(
            phase: .verifying,
            downloadedBytes: actualSize,
            totalBytes: actualSize,
            isFinal: true
        ))
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
