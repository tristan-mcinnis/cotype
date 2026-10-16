import XCTest
import Foundation
@testable import CotypeCore

final class NotarizationCheckerTests: XCTestCase {

    private let bundleURL = URL(fileURLWithPath: "/tmp/fake/Cotype.app")

    /// spctl accepts with source=Notarized Developer ID, codesign succeeds with a
    /// Developer ID Application authority.
    private func notarizedRunner(size: Int32 = 0, codesignStatusOff: Int32? = nil) -> NotarizationChecker.CommandRunner {
        { exec, _ in
            if exec == "/usr/sbin/spctl" {
                return (0, "/tmp/fake/Cotype.app: accepted\nsource=Notarized Developer ID\n")
            }
            if exec == "/usr/bin/codesign" {
                let status = codesignStatusOff ?? 0
                return (status, status == 0 ? "Authority=Developer ID Application: Acme (ABCDE12345)\n" : "")
            }
            return (1, "")
        }
    }

    func testNotarizedWhenAcceptedAndNotarizedDeveloperIDAndCodesignOK() {
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: notarizedRunner())
        XCTAssertTrue(status.accepted)
        XCTAssertTrue(status.codesignAccepted)
        XCTAssertTrue(status.isDeveloperID)
        XCTAssertTrue(status.notarized)
        XCTAssertEqual(status.normalizedSource, "notarized developer id")
    }

    func testNotarizedWhitespaceTolerantSource() {
        let runner: NotarizationChecker.CommandRunner = { exec, _ in
            if exec == "/usr/sbin/spctl" {
                return (0, "/tmp/fake/Cotype.app: accepted\nsource=  Notarized   Developer ID  \n")
            }
            return (0, "Authority=Developer ID Application: Acme (ABCDE12345)\n")
        }
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: runner)
        XCTAssertTrue(status.notarized, "whitespace-collapsed source should match")
    }

    func testAcceptedNotNotarizedSourceIsNotNotarized() {
        // spctl exit 0 but source is Apple Development — MUST NOT be treated as
        // notarized. This is the exact failure the reviewer flagged.
        let runner: NotarizationChecker.CommandRunner = { exec, _ in
            if exec == "/usr/sbin/spctl" {
                return (0, "/tmp/fake/Cotype.app: accepted\nsource=Apple Development\n")
            }
            return (0, "Authority=Apple Development: Acme (ABCDE12345)\n")
        }
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: runner)
        XCTAssertTrue(status.accepted)
        XCTAssertFalse(status.notarized)
    }

    func testNotarizedSourceButCodesignFailIsNotNotarized() {
        // source says Notarized Developer ID but codesign failed (non-zero) — the
        // authority is unverifiable, so notarization must NOT be claimed.
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: notarizedRunner(codesignStatusOff: 1))
        XCTAssertTrue(status.accepted)
        XCTAssertFalse(status.codesignAccepted)
        XCTAssertFalse(status.notarized)
    }

    func testNotarizedSourceButNonDeveloperIDAuthorityIsNotNotarized() {
        // source says Notarized Developer ID, codesign runs, but the authority is
        // NOT a Developer ID Application — must not be treated as notarized.
        let runner: NotarizationChecker.CommandRunner = { exec, _ in
            if exec == "/usr/sbin/spctl" {
                return (0, "/tmp/fake/Cotype.app: accepted\nsource=Notarized Developer ID\n")
            }
            return (0, "Authority=Apple Development: Acme (ABCDE12345)\n")
        }
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: runner)
        XCTAssertTrue(status.accepted)
        XCTAssertTrue(status.codesignAccepted)
        XCTAssertFalse(status.isDeveloperID)
        XCTAssertFalse(status.notarized)
    }

    func testRejectedIsNotNotarized() {
        let runner: NotarizationChecker.CommandRunner = { exec, _ in
            if exec == "/usr/sbin/spctl" { return (2, "/tmp/fake/Cotype.app: rejected\nsource=No usable signature\n") }
            return (0, "Authority=ad-hoc\n")
        }
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: runner)
        XCTAssertFalse(status.accepted)
        XCTAssertFalse(status.notarized)
    }

    func testToolCannotRunIsNotNotarized() {
        let runner: NotarizationChecker.CommandRunner = { _, _ in (Int32.max, "") }
        let status = NotarizationChecker().assess(bundleURL: bundleURL, runCommand: runner)
        XCTAssertFalse(status.accepted)
        XCTAssertFalse(status.notarized)
        XCTAssertFalse(status.isDeveloperID)
    }

    func testPassesVerboseArgsAndBundlePathToSpctl() {
        var spctlInvocation: [String]?
        _ = NotarizationChecker().assess(bundleURL: bundleURL) { exec, args in
            if exec == "/usr/sbin/spctl" { spctlInvocation = args }
            return (0, "")
        }
        XCTAssertEqual(spctlInvocation, ["-a", "-vvv", "-t", "exec", bundleURL.path])
    }
}
