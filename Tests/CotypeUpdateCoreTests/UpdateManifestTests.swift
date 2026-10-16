import XCTest
import Foundation
import CryptoKit
@testable import CotypeUpdateCore

final class UpdateManifestTests: XCTestCase {

    private func makeManifest(
        version: String = "0.1.1",
        buildNumber: String = "120",
        sha256: String = String(repeating: "abc", count: 21) + "d", // 64 chars
        signature: UpdateManifest.Signature? = nil,
        artifacts: [UpdateManifest.Artifact]? = nil
    ) -> UpdateManifest {
        UpdateManifest(
            appIdentifier: "com.tristan.cotype",
            product: "cotype-menu",
            version: version,
            buildNumber: buildNumber,
            minimumOSVersion: "14.0",
            commit: "abc1234",
            buildMode: "release",
            createdAt: "2026-08-29T00:00:00Z",
            artifacts: artifacts ?? [.init(
                filename: "Cotype-\(version).zip",
                kind: "zip",
                size: 1234,
                sha256: sha256,
                url: "https://example.com/Cotype-\(version).zip"
            )],
            signature: signature
        )
    }

    func testValidManifestPassesValidation() {
        let issues = UpdateManifestValidator.validate(makeManifest())
        XCTAssertTrue(issues.isEmpty, "expected valid manifest, got \(issues)")
    }

    func testInvalidSchemaVersionRejected() {
        var m = makeManifest()
        m.schemaVersion = 2
        let issues = UpdateManifestValidator.validate(m)
        XCTAssertTrue(issues.contains { $0.contains("schemaVersion") })
    }

    func testBadVersionRejected() {
        let issues = UpdateManifestValidator.validate(makeManifest(version: "not-a-version"))
        XCTAssertTrue(issues.contains { $0.contains("version") })
    }

    func testNonSemverVersionRejected() {
        let issues = UpdateManifestValidator.validate(makeManifest(version: "1.2"))
        XCTAssertTrue(issues.contains { $0.contains("version") })
    }

    func testZeroBuildNumberRejected() {
        let issues = UpdateManifestValidator.validate(makeManifest(buildNumber: "0"))
        XCTAssertTrue(issues.contains { $0.contains("buildNumber") })
    }

    func testNegativeBuildNumberRejected() {
        let issues = UpdateManifestValidator.validate(makeManifest(buildNumber: "-3"))
        XCTAssertTrue(issues.contains { $0.contains("buildNumber") })
    }

    func testBadSHA256Rejected() {
        let issues = UpdateManifestValidator.validate(makeManifest(sha256: "abc123"))
        XCTAssertTrue(issues.contains { $0.contains("sha256") })
    }

    func testEmptyArtifactsRejected() {
        let issues = UpdateManifestValidator.validate(makeManifest(artifacts: []))
        XCTAssertTrue(issues.contains { $0.contains("no artifacts") })
    }

    func testMissingSignatureIsValidUnlessRequired() {
        let manifest = makeManifest()
        XCTAssertTrue(UpdateManifestValidator.validate(manifest).isEmpty)
        XCTAssertNil(manifest.signature)
    }

    func testBadSignatureLengthRejected() {
        let sig = UpdateManifest.Signature(algorithm: "Ed25519", value: Data([0x00]).base64EncodedString())
        let issues = UpdateManifestValidator.validate(makeManifest(signature: sig))
        XCTAssertTrue(issues.contains { $0.contains("signature") })
    }

    func testWrongAlgorithmRejected() {
        let sig = UpdateManifest.Signature(algorithm: "RSA", value: Data(repeating: 0, count: 64).base64EncodedString())
        let issues = UpdateManifestValidator.validate(makeManifest(signature: sig))
        XCTAssertTrue(issues.contains { $0.contains("Ed25519") })
    }

    func testValidSHA256Format() {
        XCTAssertTrue(UpdateManifestValidator.isHexSHA256(String(repeating: "a", count: 64)))
        XCTAssertFalse(UpdateManifestValidator.isHexSHA256(String(repeating: "z", count: 64)))
        XCTAssertFalse(UpdateManifestValidator.isHexSHA256("abc"))
    }

    // MARK: Version ordering

    func testVersionOrderingAscending() {
        // `.ascending` means lhs sorts before rhs, i.e. lhs is OLDER.
        XCTAssertEqual(ReleaseVersionOrdering.compare("0.1.0", "0.1.1"), .ascending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("0.9.9", "1.0.0"), .ascending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("0.1.9", "0.2.0"), .ascending)
    }

    func testVersionOrderingSame() {
        XCTAssertEqual(ReleaseVersionOrdering.compare("0.1.1", "0.1.1"), .same)
    }

    func testVersionOrderingDescending() {
        // `.descending` means lhs sorts after rhs, i.e. lhs is NEWER.
        XCTAssertEqual(ReleaseVersionOrdering.compare("0.1.1", "0.1.0"), .descending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0", "0.9.9"), .descending)
    }

    func testVersionOrderingInvalid() {
        XCTAssertEqual(ReleaseVersionOrdering.compare("x", "0.1.0"), .invalid("cannot parse 'x' vs '0.1.0'"))
    }

    func testIsStrictlyNewer() {
        XCTAssertTrue(ReleaseVersionOrdering.isStrictlyNewer("0.1.1", than: "0.1.0"))
        XCTAssertFalse(ReleaseVersionOrdering.isStrictlyNewer("0.1.0", than: "0.1.1"))
        XCTAssertFalse(ReleaseVersionOrdering.isStrictlyNewer("0.1.0", than: "0.1.0"))
    }

    // MARK: SemVer prerelease precedence

    func testReleaseOrdersAfterPrereleaseOfSameCore() {
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0", "1.0.0-rc.1"), .descending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-rc.1", "1.0.0"), .ascending)
    }

    func testPrereleaseIdentifiersOrderNumericThenLexical() {
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-beta", "1.0.0-alpha"), .descending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-alpha.2", "1.0.0-alpha.1"), .descending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-beta.11", "1.0.0-beta.2"), .descending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-rc.1", "1.0.0-beta"), .descending)
    }

    func testNumericIdentifierRanksBelowAlphanumeric() {
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-1", "1.0.0-alpha"), .ascending)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-alpha", "1.0.0-1"), .descending)
    }

    func testBuildMetadataIsIgnored() {
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0+build.5", "1.0.0"), .same)
        XCTAssertEqual(ReleaseVersionOrdering.compare("1.0.0-rc.1+build.5", "1.0.0-rc.1"), .same)
    }

    func testPrereleaseMonotonicity() {
        // Build numbers always advance over time; the prerelease ships first
        // (build 121) and the full release later (build 122).
        let release = makeManifest(version: "1.0.0", buildNumber: "122")
        let prerelease = makeManifest(version: "1.0.0-rc.1", buildNumber: "121")
        // Shipping a prerelease AFTER the release is a version downgrade.
        XCTAssertFalse(ReleaseVersionOrdering.isMonotonic(next: prerelease, previous: release))
        // Promoting a prerelease to a release with a higher build is a valid bump.
        XCTAssertTrue(ReleaseVersionOrdering.isMonotonic(next: release, previous: prerelease))
    }

    // MARK: Build-number monotonicity

    func testBuildMonotonicity() {
        XCTAssertTrue(ReleaseVersionOrdering.monotonicBuildNumber(nextBuild: "121", previousBuild: "120"))
        XCTAssertFalse(ReleaseVersionOrdering.monotonicBuildNumber(nextBuild: "120", previousBuild: "120"))
        XCTAssertFalse(ReleaseVersionOrdering.monotonicBuildNumber(nextBuild: "119", previousBuild: "120"))
        XCTAssertFalse(ReleaseVersionOrdering.monotonicBuildNumber(nextBuild: "0", previousBuild: "120"))
    }

    func testManifestMonotonicity() {
        let older = makeManifest(version: "0.1.0", buildNumber: "119")
        let newer = makeManifest(version: "0.1.1", buildNumber: "120")
        XCTAssertTrue(ReleaseVersionOrdering.isMonotonic(next: newer, previous: older))

        // Same version but build did not advance -> not monotonic.
        let sameVersion = makeManifest(version: "0.1.1", buildNumber: "120")
        XCTAssertFalse(ReleaseVersionOrdering.isMonotonic(next: sameVersion, previous: newer))

        // Version downgrade -> not monotonic.
        let downgrade = makeManifest(version: "0.1.0", buildNumber: "140")
        XCTAssertFalse(ReleaseVersionOrdering.isMonotonic(next: downgrade, previous: newer))
    }

    // MARK: Ed25519 signing round-trip

    func testSignVerifyRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation

        let manifest = makeManifest()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)

        let signature = try ManifestSignature.sign(manifestJSON: data, privateKey: privateKey.rawRepresentation)

        XCTAssertTrue(ManifestSignature.verify(
            manifestJSON: data, base64Signature: signature, publicKey: publicKey
        ))
    }

    func testTamperedManifestFailsVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let original = try encoder.encode(makeManifest(version: "0.1.1"))
        let signature = try ManifestSignature.sign(manifestJSON: original, privateKey: privateKey.rawRepresentation)

        let tampered = try encoder.encode(makeManifest(version: "0.1.2"))
        XCTAssertFalse(ManifestSignature.verify(
            manifestJSON: tampered, base64Signature: signature, publicKey: publicKey
        ))
    }

    func testWrongKeyFailsVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(makeManifest())
        let signature = try ManifestSignature.sign(manifestJSON: data, privateKey: privateKey.rawRepresentation)

        XCTAssertFalse(ManifestSignature.verify(
            manifestJSON: data, base64Signature: signature, publicKey: otherKey.publicKey.rawRepresentation
        ))
    }

    func testSignedManifestPayloadStable() throws {
        // Signing an unsigned manifest and then re-serializing with the signature
        // must produce the same canonical payload, so verify-after-attach works.
        let privateKey = Curve25519.Signing.PrivateKey()
        _ = privateKey.publicKey.rawRepresentation

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let unsigned = try encoder.encode(makeManifest())
        let signature = try ManifestSignature.sign(manifestJSON: unsigned, privateKey: privateKey.rawRepresentation)

        let signed = try attachSignature(to: unsigned, value: signature)
        let reDecoded = try JSONDecoder().decode(UpdateManifest.self, from: signed)
        XCTAssertEqual(reDecoded.signature?.value, signature)
        XCTAssertNil(try JSONDecoder().decode(UpdateManifest.self, from: unsigned).signature)

        // The payload over the signed manifest must match the unsigned payload.
        XCTAssertEqual(
            try ManifestSignature.payload(bytes: unsigned),
            try ManifestSignature.payload(bytes: signed)
        )
    }
}

/// Local re-implementation used only in tests to attach a signature the same way
/// the `cotype-update` CLI does (so the payload-stability test is self-contained).
private func attachSignature(to manifestJSON: Data, value: String) throws -> Data {
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
    struct WithSig: Codable {
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
        var signature: UpdateManifest.Signature
    }
    let bare = try JSONDecoder().decode(Bare.self, from: manifestJSON)
    let withSig = WithSig(
        schemaVersion: bare.schemaVersion, appIdentifier: bare.appIdentifier, product: bare.product,
        version: bare.version, buildNumber: bare.buildNumber, minimumOSVersion: bare.minimumOSVersion,
        commit: bare.commit, buildMode: bare.buildMode, createdAt: bare.createdAt, artifacts: bare.artifacts,
        signature: .init(algorithm: "Ed25519", value: value)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(withSig)
}
