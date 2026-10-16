import Foundation

/// The outcome of verifying an on-disk model file against its pinned size and
/// SHA-256. This is the single, authoritative integrity check — a size+mtime
/// marker is only a UX cache, never an integrity decision.
public enum ModelVerificationStatus: Equatable, Sendable {
    case verified
    /// The file exists but its size or SHA-256 does not match the pin.
    case corrupt(String)
    /// No file at the expected path.
    case missing
    /// Verification could not be completed (e.g. unreadable file).
    case error(String)
}

/// Verifies an on-disk GGUF against the expected size + SHA-256. Hashing runs
/// off the main actor and concurrent requests for the same file are coalesced so
/// a multi-GB model is never hashed twice at once.
public protocol ModelVerifying: Sendable {
    var expectedSize: Int64 { get }
    var expectedSHA256: String { get }
    func verify(_ url: URL) async -> ModelVerificationStatus
}

/// The canonical `ModelVerifying` implementation. Thread-safe; concurrent
/// `verify` calls for the same URL share one hashing task.
public final class ModelIntegrityVerifier: ModelVerifying, @unchecked Sendable {

    public let expectedSize: Int64
    public let expectedSHA256: String

    private let lock = NSLock()
    private var inFlight: [URL: Task<ModelVerificationStatus, Never>] = [:]

    public init(expectedSize: Int64, expectedSHA256: String) {
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
    }

    /// Verify a file. The SHA-256 read is performed on a background task; if a
    /// verification for the same URL is already in flight it is reused. Each call
    /// re-reads the file — there is no cached "verified" result, so a replaced
    /// file can never be served a stale verification.
    public func verify(_ url: URL) async -> ModelVerificationStatus {
        // Reuse an in-flight verification for the same URL, or start a new one.
        // Scoped locking avoids `NSLock.lock`/`unlock` in async context.
        let (task, created) = lock.withLock { () -> (Task<ModelVerificationStatus, Never>, Bool) in
            if let existing = inFlight[url] {
                return (existing, false)
            }
            let fresh = Task.detached(priority: .utility) { [expectedSize, expectedSHA256] in
                Self.check(url, expectedSize: expectedSize, expectedSHA256: expectedSHA256)
            }
            inFlight[url] = fresh
            return (fresh, true)
        }

        let result = await task.value
        if created {
            lock.withLock { _ = inFlight.removeValue(forKey: url) }
        }
        return result
    }

    static func check(_ url: URL, expectedSize: Int64, expectedSHA256: String) -> ModelVerificationStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }

        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return .error("size")
        }
        guard size.int64Value == expectedSize else {
            return .corrupt("expected \(expectedSize) bytes, found \(size.int64Value)")
        }

        guard let digest = try? sha256OfFile(at: url) else {
            return .error("hash")
        }
        guard digest == expectedSHA256 else {
            return .corrupt("SHA-256 mismatch")
        }
        return .verified
    }
}
