import XCTest
import Foundation
@testable import CotypeCore

/// Repo-wide guard against the model catalog / tooling drifting or regressing:
///   - the pinned catalog (`ModelSpec.gemma4E2BIt`) must match the model pin in
///     `scripts/shared.sh` (filename + SHA-256),
///   - the pinned model must be Apache-2.0 (Gemma 4 is Apache-2.0, not the old
///     Gemma Terms of Use),
///   - the legacy base-model pin (filename / SHA-256) must not reappear in
///     production source, tooling, CI, or docs — only the migration helper and
///     the migration tests may name it.
final class ModelCatalogConsistencyTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ModelCatalogConsistencyTests.swift
            .deletingLastPathComponent()   // CotypeCoreTests
            .deletingLastPathComponent()   // Tests
    }

    private let legacyFilename = "gemma-4-E2B-i1-Q4_K_M.gguf"
    private let legacySha = "61bf05f5e916e0b7faba9324c7c11ae0dbc9d93337094192182911aa6c98c96f"

    func testPinnedCatalogIsApacheAndMatchesSharedScript() throws {
        let spec = ModelSpec.gemma4E2BIt
        XCTAssertTrue(spec.license.lowercased().contains("apache"),
                      "Gemma 4 is Apache-2.0; catalog license must not claim Gemma Terms")
        XCTAssertFalse(spec.license.lowercased().contains("gemma terms"))

        let shared = try String(contentsOf: repoRoot.appendingPathComponent("scripts/shared.sh"), encoding: .utf8)
        XCTAssertTrue(
            shared.contains("COTYPE_MODEL_FILENAME=\"${COTYPE_MODEL_FILENAME:-\(spec.managedFilename)}\""),
            "scripts/shared.sh model filename must match the catalog"
        )
        XCTAssertTrue(
            shared.contains("COTYPE_MODEL_SHA256=\"${COTYPE_MODEL_SHA256:-\(spec.expectedSHA256)}\""),
            "scripts/shared.sh model SHA-256 must match the catalog"
        )
    }

    func testLegacyBaseModelNotReferencedInProductionOrDocs() throws {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: repoRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        var offenders: [String] = []

        for case let url as URL in enumerator {
            let path = url.path
            // Skip build artifacts / git metadata.
            if path.contains("/.build/") || path.contains("/.git/") { continue }
            // Only production source, tooling, CI, and docs — tests are allowed
            // to exercise the migration path.
            guard path.contains("/Sources/") || path.contains("/scripts/")
                || path.contains("/.github/") || path.hasSuffix("/README.md")
                || path.contains("/docs/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains(legacySha) || text.contains(legacyFilename) else { continue }
            // The migration helper legitimately names the legacy filename to
            // remove it; that is the only allowed production reference.
            if path.hasSuffix("/Sources/CotypeCore/ModelMigration.swift") { continue }
            offenders.append(path)
        }

        XCTAssertTrue(offenders.isEmpty,
                      "Legacy base-model pin references must not remain: \(offenders)")
    }
}
