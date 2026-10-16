import Foundation
import CryptoKit
import CotypeUpdateCore

// cotype-update: the release/update-channel CLI contract.
//
//   cotype-update keygen [--out <dir>]
//       Generate an Ed25519 signing keypair. Writes ed25519-private.key and
//       ed25519-public.key (32-byte hex each) into the directory.
//
//   cotype-update sign --manifest <json> --key <private.key> [--out <file>]
//       Sign an unsigned update-manifest.json with the Ed25519 private key and
//       write the signed manifest (with the `signature` field) to --out or stdout.
//
//   cotype-update verify --manifest <json> --key <public.key>
//       Verify the signature on a signed manifest. Exit 0 when valid, 1 when not.
//
//   cotype-update validate --manifest <json> [--require-signature]
//       Run the structural manifest validator. Exit 0 when valid, 1 when not.
//
//   cotype-update self-test
//       Deterministic in-memory round-trip used by `--self-test` on the release
//       scripts. Exit 0 on success, non-zero on failure.

func writeErr(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

func readFile(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

func writeFile(_ data: Data, to path: String?) throws {
    if let path {
        try data.write(to: URL(fileURLWithPath: path))
    } else {
        FileHandle.standardOutput.write(data)
    }
}

func flagValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// Decode an Ed25519 key given as 64 hex chars or as base64 of the 32 raw bytes.
/// The canonical secret format is base64 (matches Sparkle's SUPublicEDKey); hex is
/// accepted for backwards compatibility.
func decodeKey(_ value: String) throws -> Data {
    let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count == 64, let raw = try? Data(hexString: t) { return raw }
    if t.count % 4 == 0, let base64 = Data(base64Encoded: t), base64.count == 32 { return base64 }
    throw UpdateError("key must be 32 bytes (64 hex chars or base64)")
}

struct UpdateError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    writeErr("usage: cotype-update <keygen|sign|verify|validate|self-test> [flags]")
    exit(2)
}

let command = args[1]

do {
    switch command {
    case "keygen":
        let outDir = flagValue("--out") ?? "."
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let privateKey = Curve25519.Signing.PrivateKey()
        // Canonical on-disk format is base64 of the 32 raw bytes, so the same
        // value can be used verbatim for Sparkle's SUPublicEDKey and for CI
        // secrets. Hex is also written for backward-compatible tooling.
        let privB64 = privateKey.rawRepresentation.base64EncodedString()
        let pubB64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        try Data(privB64.utf8).write(to: URL(fileURLWithPath: outDir + "/ed25519-private.key"))
        try Data(pubB64.utf8).write(to: URL(fileURLWithPath: outDir + "/ed25519-public.key"))
        try Data((hex(privateKey.rawRepresentation) + "\n").utf8).write(to: URL(fileURLWithPath: outDir + "/ed25519-private.key.hex"))
        try Data((hex(privateKey.publicKey.rawRepresentation) + "\n").utf8).write(to: URL(fileURLWithPath: outDir + "/ed25519-public.key.hex"))
        print("wrote \(outDir)/ed25519-private.key")
        print("wrote \(outDir)/ed25519-public.key")

    case "sign":
        guard let manifestPath = flagValue("--manifest"),
              let keyPath = flagValue("--key") else {
            throw UpdateError("sign requires --manifest <json> --key <private.key>")
        }
        let manifestData = try readFile(manifestPath)
        let key = try decodeKey(String(decoding: readFile(keyPath), as: UTF8.self))
        let signature = try ManifestSignature.sign(manifestJSON: manifestData, privateKey: key)
        // Re-serialize the manifest with the signature attached.
        let signed = try manifestWithSignature(manifestJSON: manifestData, base64Signature: signature)
        try writeFile(signed, to: flagValue("--out"))

    case "verify":
        guard let manifestPath = flagValue("--manifest"),
              let keyPath = flagValue("--key") else {
            throw UpdateError("verify requires --manifest <json> --key <public.key>")
        }
        let manifestData = try readFile(manifestPath)
        let key = try decodeKey(String(decoding: readFile(keyPath), as: UTF8.self))
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestData),
              let signatureValue = manifest.signature?.value else {
            writeErr("verify: manifest has no signature")
            exit(1)
        }
        if ManifestSignature.verify(manifestJSON: manifestData, base64Signature: signatureValue, publicKey: key) {
            exit(0)
        } else {
            writeErr("verify: signature is invalid")
            exit(1)
        }

    case "validate":
        guard let manifestPath = flagValue("--manifest") else {
            throw UpdateError("validate requires --manifest <json>")
        }
        let manifestData = try readFile(manifestPath)
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestData) else {
            writeErr("validate: manifest is not valid JSON of the expected schema")
            exit(1)
        }
        var issues = UpdateManifestValidator.validate(manifest)
        if hasFlag("--require-signature"), manifest.signature == nil {
            issues.append("--require-signature: manifest has no signature")
        }
        if issues.isEmpty {
            exit(0)
        } else {
            for issue in issues { writeErr("validate: \(issue)") }
            exit(1)
        }

    case "derive-public":
        // derive-public --private-key <file>: print the base64 Ed25519 public key
        // that matches the given private key. Used by generate-appcast.sh to verify
        // the signing key actually corresponds to the app's embedded SUPublicEDKey.
        guard let keyFile = flagValue("--private-key") else {
            writeErr("derive-public requires --private-key <file>")
            exit(2)
        }
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: try decodeKey(String(decoding: try readFile(keyFile), as: UTF8.self))
        )
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())

    case "compare":
        // compare <a> <b>: exit 0 when a is STRICTLY newer than b, 1 when a is
        // not newer, 2 when either version is malformed. Used by the shell
        // release gates, so shell and Swift share one tested semver authority.
        guard args.count >= 4 else {
            writeErr("compare requires two versions (a b)")
            exit(2)
        }
        let a = args[2]
        let b = args[3]
        switch ReleaseVersionOrdering.compare(a, b) {
        case .descending:
            exit(0)
        case .ascending, .same:
            exit(1)
        case .invalid(let message):
            writeErr("compare: \(message)")
            exit(2)
        }

    case "self-test":
        // Deterministic round-trip: keygen -> sign -> verify, plus validator checks.
        let privateKey = Curve25519.Signing.PrivateKey()
        let pub = privateKey.publicKey.rawRepresentation

        let manifest = UpdateManifest(
            appIdentifier: "com.tristan.cotype",
            product: "cotype-menu",
            version: "0.1.1",
            buildNumber: "120",
            minimumOSVersion: "14.0",
            commit: "abc1234",
            buildMode: "release",
            createdAt: "2026-08-29T00:00:00Z",
            artifacts: [.init(filename: "Cotype-0.1.1.zip", kind: "zip", size: 1234,
                              sha256: String(repeating: "a", count: 64), url: "https://example/Cotype-0.1.1.zip")]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let unsigned = try encoder.encode(manifest)
        let signature = try ManifestSignature.sign(manifestJSON: unsigned, privateKey: privateKey.rawRepresentation)
        let signed = try manifestWithSignature(manifestJSON: unsigned, base64Signature: signature)
        let signedManifest = try JSONDecoder().decode(UpdateManifest.self, from: signed)

        var ok = true
        if !ManifestSignature.verify(manifestJSON: signed, base64Signature: signature, publicKey: pub) {
            writeErr("self-test: signature did not verify"); ok = false
        }
        let issues = UpdateManifestValidator.validate(signedManifest)
        if !issues.isEmpty {
            writeErr("self-test: validator rejected signed manifest: \(issues)"); ok = false
        }
        if !ReleaseVersionOrdering.isStrictlyNewer("0.1.1", than: "0.1.0") {
            writeErr("self-test: version ordering failed"); ok = false
        }
        if ReleaseVersionOrdering.isStrictlyNewer("0.1.0", than: "0.1.1") {
            writeErr("self-test: version ordering accepted a downgrade"); ok = false
        }
        // Build-number monotonicity.
        if !ReleaseVersionOrdering.monotonicBuildNumber(nextBuild: "121", previousBuild: "120") {
            writeErr("self-test: build monotonicity failed"); ok = false
        }
        if ReleaseVersionOrdering.monotonicBuildNumber(nextBuild: "120", previousBuild: "121") {
            writeErr("self-test: build monotonicity accepted a regression"); ok = false
        }
        exit(ok ? 0 : 1)

    default:
        writeErr("unknown command: \(command)")
        exit(2)
    }
} catch {
    writeErr("cotype-update: \(error)")
    exit(1)
}

/// Attach a signature to an unsigned manifest by decoding, adding the signature
/// field, and re-serializing canonically. The resulting bytes, when passed
/// through `ManifestSignature.payload`, reproduce the unsigned payload.
func manifestWithSignature(manifestJSON: Data, base64Signature: String) throws -> Data {
    struct WithSignature: Codable {
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
    let signed = WithSignature(
        schemaVersion: bare.schemaVersion,
        appIdentifier: bare.appIdentifier,
        product: bare.product,
        version: bare.version,
        buildNumber: bare.buildNumber,
        minimumOSVersion: bare.minimumOSVersion,
        commit: bare.commit,
        buildMode: bare.buildMode,
        createdAt: bare.createdAt,
        artifacts: bare.artifacts,
        signature: .init(algorithm: "Ed25519", value: base64Signature)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(signed)
}

private extension Data {
    init(hexString: String) throws {
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw UpdateError("invalid hex byte in key")
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
