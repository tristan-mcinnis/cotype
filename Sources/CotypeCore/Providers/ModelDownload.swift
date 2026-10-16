import Foundation
import CryptoKit

// MARK: - ModelDescriptor

/// Identifies a single GGUF model file on Hugging Face and where it should
/// land on disk. Pure value type, so it can be hashed and used as a cache key.
public struct ModelDescriptor: Hashable {
    /// Hugging Face repo, e.g. "TheBloke/Llama-2-7B-GGUF".
    public var repo: String
    /// File name inside the repo, e.g. "llama-2-7b.Q4_K_M.gguf".
    public var filename: String
    /// Git commit (or branch/tag) to pin the resolve URL to. Pinning a commit
    /// makes a managed model reproducible: the bytes never drift between runs
    /// while the rest of the app evolves.
    public var revision: String
    /// Where the downloaded bytes should be written on the local filesystem.
    public var destination: URL

    public init(repo: String, filename: String, destination: URL, revision: String = "main") {
        self.repo = repo
        self.filename = filename
        self.revision = revision
        self.destination = destination
    }

    /// The Hugging Face "resolve" URL that 302-redirects to the CDN. URLSession
    /// follows that redirect automatically. Each path component is
    /// percent-encoded so repo/file names with spaces or special characters
    /// resolve correctly (a repo's `/` separates segments, so it is split).
    public var resolvedURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        let segments = repo.split(separator: "/").map(String.init) + ["resolve", revision, filename]
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encoded = segments.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
        }
        components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        return components.url ?? URL(string: "https://huggingface.co/")!
    }
}

// MARK: - DownloadProgress

/// Snapshot of a download's state, emitted as bytes land on disk.
public struct DownloadProgress {
    /// Bytes persisted so far (includes any bytes resumed from disk).
    public let downloadedBytes: Int64
    /// Total bytes for the file, when known. `nil` when the server did not
    /// announce a size.
    public let totalBytes: Int64?
    /// True only for the final event, after the last chunk is flushed.
    public let isComplete: Bool

    public init(downloadedBytes: Int64, totalBytes: Int64?, isComplete: Bool) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isComplete = isComplete
    }
}

// MARK: - Errors

public enum ModelDownloadError: LocalizedError {
    case rangeMismatch
    case unexpectedStatus(Int)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .rangeMismatch:
            return "The server returned a byte range that does not match the local partial file."
        case .unexpectedStatus(let code):
            return "Unexpected HTTP status \(code) while downloading the model."
        case .insufficientDiskSpace(let required, let available):
            return "Not enough free disk space. Need \(String(format: "%.1f GB", Double(required) / 1_000_000_000)), have \(String(format: "%.1f GB", Double(available) / 1_000_000_000))."
        case .sizeMismatch(let expected, let actual):
            return "Downloaded model size does not match. Expected \(expected) bytes, got \(actual) bytes."
        case .checksumMismatch(let expected, let actual):
            return "Checksum verification failed. Expected SHA-256 \(expected), got \(actual). The file may be corrupt and was removed."
        }
    }
}

// MARK: - SHA-256 and disk-space helpers

/// Computes the hex-encoded SHA-256 of a file, streaming it in 1 MiB chunks so
/// a multi-gigabyte model never loads fully into memory.
public func sha256OfFile(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Free bytes available for important data on the volume holding `url`'s parent
/// directory. Returns `0` when the value cannot be read.
public func freeDiskSpace(at url: URL) -> Int64 {
    let volume = url.deletingLastPathComponent()
    guard let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
        return 0
    }
    return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
}

// MARK: - GGUFDownloader

/// Downloads a `ModelDescriptor` to its destination with resume support.
///
/// Highlights:
///  - If the destination already exists and is non-empty, a `Range` header
///    (`bytes=<size>-`) is sent and the response is *appended* to the file.
///  - Otherwise a fresh GET is issued and the file is written from scratch.
///  - A 206 response is validated so we never append at the wrong offset.
///  - A 416 response on an already-complete file is treated as a successful
///    no-op (idempotent re-runs).
///  - The body is streamed to disk by `URLSession` (no byte-by-byte awaits, no
///    whole-file memory residency).
///  - Hugging Face's 302 redirect is followed automatically (left enabled).
///
/// A `URLSession` is injected (default `.shared`) so tests can substitute a
/// stub via `URLProtocol`.
public final class GGUFDownloader {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Streams download progress for `descriptor` into an
    /// `AsyncThrowingStream`. Emits a `DownloadProgress` as chunks land,
    /// including a final `isComplete == true` event before finishing.
    public func download(_ descriptor: ModelDescriptor) -> AsyncThrowingStream<DownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self._download(descriptor) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func _download(
        _ descriptor: ModelDescriptor,
        onProgress: @escaping (DownloadProgress) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: descriptor.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existingSize = fileSize(at: descriptor.destination)
        let offset = existingSize

        var request = URLRequest(url: descriptor.resolvedURL)
        if existingSize > 0 {
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
        }

        // The delegate reports bytes written during *this* task (starting at 0);
        // add `offset` back to reflect the true on-disk total.
        let delegate = DownloadProgressDelegate { written, expected, statusCode in
            // A server may ignore Range and return 200. In that case the temp
            // body will overwrite the partial file, so progress starts at zero.
            let base = statusCode == 206 ? offset : 0
            let total: Int64? = expected >= 0 ? base + expected : nil
            onProgress(DownloadProgress(downloadedBytes: base + written, totalBytes: total, isComplete: false))
        }

        let (tempURL, response) = try await session.download(for: request, delegate: delegate)
        defer { try? fileManager.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let bodySize = fileSize(at: tempURL)
        let append: Bool

        switch http.statusCode {
        case 200:
            // Full body. If we had a partial file, the server ignored our Range,
            // so overwrite from scratch rather than double up.
            append = false
        case 206:
            // Partial content. Validate the server honored our exact range start;
            // appending at a different offset would silently corrupt the file.
            guard let range = parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == offset else {
                throw ModelDownloadError.rangeMismatch
            }
            append = true
        case 416:
            // Range Not Satisfiable. If the file is already complete this is a
            // successful no-op (idempotent), otherwise the range was invalid.
            if let range = parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
               range.total == offset {
                onProgress(DownloadProgress(downloadedBytes: offset, totalBytes: offset, isComplete: true))
                return
            }
            throw ModelDownloadError.unexpectedStatus(416)
        default:
            throw ModelDownloadError.unexpectedStatus(http.statusCode)
        }

        // Move the temp body onto the destination (append or overwrite).
        try transfer(from: tempURL, to: descriptor.destination, append: append)

        let downloaded = append ? offset + bodySize : bodySize
        onProgress(DownloadProgress(downloadedBytes: downloaded, totalBytes: downloaded, isComplete: true))
    }

    // MARK: Helpers

    /// Streams `source` onto `destination` in 1 MiB chunks without loading the
    /// whole body into memory. `append == false` truncates `destination` first.
    private func transfer(from source: URL, to destination: URL, append: Bool) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        if !append {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        if append {
            try writer.seekToEnd()
        }
        while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
    }

    /// Parses a `Content-Range` header of the form `bytes <start>-<end>/<total>`
    /// or, for 416 responses, `bytes */<total>` (start/end returned as -1).
    private func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst("bytes ".count).split(separator: "/")
        guard parts.count == 2,
              let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let range = parts[0].trimmingCharacters(in: .whitespaces)
        if range == "*" {
            return (-1, -1, total)
        }
        let bounds = range.split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else { return nil }
        return (start, end, total)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

// MARK: - DownloadProgressDelegate

/// Per-task delegate bridging `URLSession` download progress to a closure.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Int64, Int64, Int?) -> Void

    init(onProgress: @escaping (Int64, Int64, Int?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        onProgress(totalBytesWritten, totalBytesExpectedToWrite, statusCode)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `download(for:delegate:)` API returns the temporary file
        // URL itself, so there is nothing to move here.
    }
}
