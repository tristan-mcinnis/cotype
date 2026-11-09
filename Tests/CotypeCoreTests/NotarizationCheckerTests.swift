import XCTest
import Foundation
@testable import CotypeCore

final class NotarizationCheckerTests: XCTestCase {

    func testRunnerDrainsOutputBeyondPipeCapacityOnBothChannels() {
        let script = "i=0; while [ $i -lt 12000 ]; do printf abcdefghij; printf klmnopqrst >&2; i=$((i+1)); done"
        let result = NotarizationChecker.runCommand("/bin/sh", ["-c", script], timeout: 10)
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1.count, 240_000)
    }

    func testRunnerBoundsSignalResistantProcessAndDiscardsPartialAssessment() {
        let start = Date()
        let script = "trap '' TERM; printf 'source=Notarized Developer ID'; while :; do :; done"
        let result = NotarizationChecker.runCommand("/bin/sh", ["-c", script], timeout: 0.1)
        XCTAssertEqual(result.0, Int32.max)
        XCTAssertEqual(result.1, "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRunnerReportsLaunchFailureWithoutAssessmentOutput() {
        let result = NotarizationChecker.runCommand("/missing/cotype-check", [], timeout: 0.1)
        XCTAssertEqual(result.0, Int32.max)
        XCTAssertTrue(result.1.isEmpty)
    }

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
        XCTAssertFalse(status.assessmentAvailable)
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
