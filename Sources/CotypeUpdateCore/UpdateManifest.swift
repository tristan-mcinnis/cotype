import Foundation
import CryptoKit

/// The signed update manifest a release channel publishes for an app.
///
/// The app fetches `update-manifest.json` from the channel, validates the
/// embedded Ed25519 signature against the channel's public key, then compares
/// `version`/`buildNumber` with the installed build to decide whether an update
/// is available. Every field is intentionally explicit so a release cannot
/// silently ship with a missing checksum or an ambiguous identity.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var appIdentifier: String
    public var product: String
    public var version: String
    public var buildNumber: String
    public var minimumOSVersion: String
    public var commit: String
    public var buildMode: String
    public var createdAt: String
    public var artifacts: [Artifact]
    public var signature: Signature?

    public struct Artifact: Codable, Equatable, Sendable {
        public var filename: String
        /// "app" for a bare .app bundle, "zip" for a zip archive, "dmg" for a disk image.
        public var kind: String
        public var size: Int
        /// Lowercase hex SHA-256 of the artifact file.
        public var sha256: String
        /// Absolute or channel-relative URL to download the artifact.
        public var url: String

        public init(filename: String, kind: String, size: Int, sha256: String, url: String) {
            self.filename = filename
            self.kind = kind
            self.size = size
            self.sha256 = sha256
            self.url = url
        }
    }

    public struct Signature: Codable, Equatable, Sendable {
        public var algorithm: String
        /// Base64-encoded Ed25519 signature over the canonical manifest payload
        /// (the entire manifest with `signature` removed, bytes as emitted).
        public var value: String

        public init(algorithm: String = "Ed25519", value: String) {
            self.algorithm = algorithm
            self.value = value
        }
    }

    public init(
        schemaVersion: Int = 1,
        appIdentifier: String,
        product: String,
        version: String,
        buildNumber: String,
        minimumOSVersion: String,
        commit: String,
        buildMode: String,
        createdAt: String,
        artifacts: [Artifact],
        signature: Signature? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appIdentifier = appIdentifier
        self.product = product
        self.version = version
        self.buildNumber = buildNumber
        self.minimumOSVersion = minimumOSVersion
        self.commit = commit
        self.buildMode = buildMode
        self.createdAt = createdAt
        self.artifacts = artifacts
        self.signature = signature
    }
}

// MARK: - Validation

/// Deterministic validation of a manifest's contents. Returns every problem
/// found, so a release can report all issues at once rather than one at a time.
public enum UpdateManifestValidator {

    public static func validate(_ manifest: UpdateManifest) -> [String] {
        var issues: [String] = []

        if manifest.schemaVersion != 1 {
            issues.append("unsupported schemaVersion \(manifest.schemaVersion) (expected 1)")
        }
        if manifest.appIdentifier.isEmpty {
            issues.append("appIdentifier is empty")
        }
        if manifest.product.isEmpty {
            issues.append("product is empty")
        }
        if !isSemver(manifest.version) {
            issues.append("version '\(manifest.version)' is not a valid semver build (expected MAJOR.MINOR.PATCH)")
        }
        if let build = Int(manifest.buildNumber), build > 0 {
            // OK — build number is a positive integer.
        } else {
            issues.append("buildNumber '\(manifest.buildNumber)' is not a positive integer")
        }
        if manifest.minimumOSVersion.isEmpty {
            issues.append("minimumOSVersion is empty")
        } else if !validVersionComponent(manifest.minimumOSVersion) {
            issues.append("minimumOSVersion '\(manifest.minimumOSVersion)' is not a plausible version")
        }
        if manifest.commit.isEmpty {
            issues.append("commit is empty")
        }
        if manifest.buildMode.isEmpty {
            issues.append("buildMode is empty")
        }

        if manifest.artifacts.isEmpty {
            issues.append("manifest declares no artifacts")
        }
        for (index, artifact) in manifest.artifacts.enumerated() {
            if artifact.filename.isEmpty {
                issues.append("artifacts[\(index)].filename is empty")
            }
            if artifact.kind.isEmpty {
                issues.append("artifacts[\(index)].kind is empty")
            }
            if artifact.size < 0 {
                issues.append("artifacts[\(index)].size is negative")
            }
            if !isHexSHA256(artifact.sha256) {
                issues.append("artifacts[\(index)].sha256 is not a 64-character hex digest")
            }
            if artifact.url.isEmpty {
                issues.append("artifacts[\(index)].url is empty")
            }
        }

        if let signature = manifest.signature {
            if signature.algorithm != "Ed25519" {
                issues.append("signature.algorithm '\(signature.algorithm)' is not Ed25519")
            }
            if let data = Data(base64Encoded: signature.value), !data.isEmpty {
                // Well-formed base64; a signature should be exactly 64 bytes for Ed25519.
                if data.count != 64 {
                    issues.append("signature has \(data.count) bytes (expected 64 for Ed25519)")
                }
            } else {
                issues.append("signature is not valid base64")
            }
        }

        return issues
    }

    public static func isValid(_ manifest: UpdateManifest) -> Bool {
        validate(manifest).isEmpty
    }

    // MARK: - Grammar helpers

    /// `MAJOR.MINOR.PATCH` with optional `-prerelease` / `+build` segments.
    public static func isSemver(_ value: String) -> Bool {
        let pattern = #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    /// A configurable-build version component (e.g. "14.0", "13.3"). Does not
    /// require the full semver triple, just a plausible numeric dotted version.
    static func validVersionComponent(_ value: String) -> Bool {
        let pattern = #"^(0|[1-9]\d*)(\.(0|[1-9]\d*)){0,2}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    static func isHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Ed25519 signature over the canonical manifest payload

/// Canonical signing over a manifest: the payload is the exact UTF-8 JSON bytes
/// of the manifest with `signature` removed (serialized with sorted keys and
/// no extra whitespace). The producer and consumer must serialize identically so
/// signatures match.
public enum ManifestSignature {

    /// The byte sequence that should be signed/verified. It is the canonical
    /// JSON of the manifest with the `signature` field stripped.
    public static func payload(bytes manifestJSON: Data) throws -> Data {
        struct Bare: Codable {
            var schemaVersion: Int
            var appIdentifier: String
            var product: String
            var version: String
            var buildNumber: String
            var minimumOSVersion: String
            var commit: String
            var buildMode: String
            var createdAt: String
            var artifacts: [UpdateManifest.Artifact]
        }
        let bare = try JSONDecoder().decode(Bare.self, from: manifestJSON)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bare)
    }

    /// Sign a manifest's canonical payload with an Ed25519 private key.
    public static func sign(manifestJSON: Data, privateKey: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let signature = try key.signature(for: payload(bytes: manifestJSON))
        return signature.base64EncodedString()
    }

    /// Verify a manifest's signature against an Ed25519 public key.
    public static func verify(manifestJSON: Data, signature: Data, publicKey: Data) -> Bool {
        guard signature.count == 64 else { return false }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        guard let payload = try? payload(bytes: manifestJSON) else { return false }
        return key.isValidSignature(signature, for: payload)
    }

    /// Parse a base64 signature and verify it against the manifest and public key.
    public static func verify(manifestJSON: Data, base64Signature: String, publicKey: Data) -> Bool {
        guard let signature = Data(base64Encoded: base64Signature) else { return false }
        return verify(manifestJSON: manifestJSON, signature: signature, publicKey: publicKey)
    }
}

// MARK: - Version ordering (monotonicity)

/// Semantic-version comparison for release monotonicity, per SemVer 2.0.0
/// precedence rules including prerelease ordering.
///
/// Precedence:
///   * MAJOR, then MINOR, then PATCH, compared numerically.
///   * A release (no prerelease) has higher precedence than any prerelease of the
///     same core version (e.g. `1.0.0-rc.1` < `1.0.0`).
///   * When both have a prerelease, identifiers are compared dot-separated:
///     numeric identifiers compare as numbers; numeric identifiers always have
///     lower precedence than alphanumeric ones; a longer prerelease with an equal
///     prefix has higher precedence. Build metadata (`+build`) is ignored.
///
/// The `Order`/`compare(_:_:)` result is used to reject a release that would
/// downgrade the marketing version. Build-number monotonicity is enforced
/// separately and deliberately is *not* part of version precedence.
public enum ReleaseVersionOrdering {

    public enum Order: Equatable {
        case ascending, same, descending, invalid(String)
    }

    private struct ParsedVersion {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: [String]
    }

    /// Parse a semver into its precedence-relevant parts. Returns nil for a core
    /// version that is not exactly three numeric components (so a malformed
    /// version reports `.invalid` rather than silently comparing wrong).
    private static func parse(
        _ value: String
    ) -> ParsedVersion? {
        // Drop build metadata (+…).
        let withoutBuild = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        // Split off the optional prerelease (-…) — a SemVer core never contains '-'
        // except as the prerelease separator.
        let parts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let core = parts[0]
        let prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        let nums = core.split(separator: ".").compactMap { Int($0) }
        guard nums.count == 3 else { return nil }
        return ParsedVersion(major: nums[0], minor: nums[1], patch: nums[2], prerelease: prerelease)
    }

    /// Compare two versions. Returns a negative value when `lhs < rhs`, zero when
    /// equal, and a positive value when `lhs > rhs`. Returns nil when either is
    /// malformed.
    private static func precedence(_ lhs: String, _ rhs: String) -> Int? {
        guard let a = parse(lhs), let b = parse(rhs) else { return nil }
        if a.major != b.major { return a.major < b.major ? -1 : 1 }
        if a.minor != b.minor { return a.minor < b.minor ? -1 : 1 }
        if a.patch != b.patch { return a.patch < b.patch ? -1 : 1 }
        return comparePrerelease(a.prerelease, b.prerelease)
    }

    /// Compare two prerelease identifier arrays. An empty array (a release) sorts
    /// higher than a non-empty array (a prerelease).
    private static func comparePrerelease(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty && b.isEmpty { return 0 }
        if a.isEmpty { return 1 }   // release > prerelease
        if b.isEmpty { return -1 }

        let count = max(a.count, b.count)
        for i in 0..<count {
            let ai = i < a.count ? a[i] : nil
            let bi = i < b.count ? b[i] : nil
            if let ai, let bi {
                let cmp = compareIdentifier(ai, bi)
                if cmp != 0 { return cmp }
            } else if ai != nil {
                return 1   // longer prerelease with equal prefix sorts higher
            } else {
                return -1
            }
        }
        return 0
    }

    /// Compare two single prerelease identifiers. Numeric identifiers compare as
    /// integers and sort lower than alphanumeric identifiers; otherwise ASCII
    /// lexical order.
    private static func compareIdentifier(_ a: String, _ b: String) -> Int {
        let aNum = Int(a)
        let bNum = Int(b)
        switch (aNum, bNum) {
        case let (x?, y?):
            return x < y ? -1 : (x > y ? 1 : 0)
        case (_?, nil):
            return -1   // numeric < alphanumeric
        case (nil, _?):
            return 1
        case (nil, nil):
            return a < b ? -1 : (a > b ? 1 : 0)
        }
    }

    /// Compare two semantic versions.`.ascending` when `lhs sorts before rhs
    /// (lhs is older), `.same` when equal, `.descending` when lhs is newer.
    public static func compare(_ lhs: String, _ rhs: String) -> Order {
        guard let result = precedence(lhs, rhs) else {
            return .invalid("cannot parse '\(lhs)' vs '\(rhs)'")
        }
        if result < 0 { return .ascending }
        if result > 0 { return .descending }
        return .same
    }

    /// True when `next` is strictly newer than `previous`.
    public static func isStrictlyNewer(_ next: String, than previous: String) -> Bool {
        compare(next, previous) == .descending
    }

    /// True when the marketing version is same-or-newer than the previous one
    /// and the build number has increased, so an update never rolls back.
    ///
    /// `compare(next, previous)` is `.descending` when `next` is the newer
    /// version (it sorts after `previous`), `.same` when equal, and `.ascending`
    /// when `next` would downgrade.
    public static func isMonotonic(next: UpdateManifest, previous: UpdateManifest) -> Bool {
        let versionOrder = compare(next.version, previous.version)
        switch versionOrder {
        case .ascending:
            // next.version < previous.version → a downgrade. Never allowed.
            return false
        case .invalid:
            return false
        case .descending, .same:
            // Same version or a bump: the build number must still advance.
            return monotonicBuildNumber(nextBuild: next.buildNumber, previousBuild: previous.buildNumber)
        }
    }

    /// Build-number monotonicity: the next build must be a strictly larger
    /// positive integer than the previous.
    public static func monotonicBuildNumber(nextBuild: String, previousBuild: String) -> Bool {
        guard let next = Int(nextBuild), let previous = Int(previousBuild),
              next > 0, previous > 0 else { return false }
        return next > previous
    }
}
