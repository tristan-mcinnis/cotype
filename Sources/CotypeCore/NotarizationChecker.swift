import Foundation

/// The result of assessing a bundle's Gatekeeper / notarization status.
public struct NotarizationStatus: Equatable, Sendable {
    /// Whether `spctl` accepted the bundle (exit 0).
    public let accepted: Bool
    /// The `source=` line from `spctl --assess -v -vvv` (e.g. "Notarized Developer ID").
    public let source: String
    /// The signing authority from `codesign -dv` (e.g. "Developer ID Application: …").
    public let identity: String
    /// Whether `codesign -dv` itself ran successfully (exit 0).
    public let codesignAccepted: Bool

    public init(accepted: Bool, source: String, identity: String, codesignAccepted: Bool) {
        self.accepted = accepted
        self.source = source
        self.identity = identity
        self.codesignAccepted = codesignAccepted
    }

    /// Normalized Gatekeeper source string: trimmed, whitespace-collapsed, lowercased.
    /// So "Notarized Developer ID" compares equal to "  Notarized   Developer ID " etc.
    public var normalizedSource: String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// True only when ALL hold: `spctl` accepts the bundle, the VERBOSE source is
    /// exactly "Notarized Developer ID", `codesign` runs successfully, and the
    /// authority is a Developer ID Application. A mere `spctl` exit-0, or an
    /// accepted Apple Development / ad-hoc build, is never treated as notarized.
    public var notarized: Bool {
        accepted
            && normalizedSource == "notarized developer id"
            && codesignAccepted
            && identity.contains("Developer ID Application")
    }

    /// True when the signature is a Developer ID Application identity.
    public var isDeveloperID: Bool {
        codesignAccepted && identity.contains("Developer ID Application")
    }
}

/// Determines a Cotype.app bundle's real notarization status by consulting
/// macOS Gatekeeper, rather than trusting a build-time Info.plist flag.
///
/// It runs `spctl --assess -v -vvv -t exec <bundle>` and parses the VERBOSE
/// assessment. A bundle is only reported as notarized when Gatekeeper both
/// ACCEPTS it (exit 0) AND the assessment `source=` is `Notarized Developer ID`,
/// and the code signature is a Developer ID Application identity. This avoids
/// equating an arbitrary `spctl` exit-0 (e.g. a locally-trusted Apple
/// Development build) with notarization. The check is a synchronous subprocess
/// helper; callers should invoke it off the main UI thread (see the About pane).
public struct NotarizationChecker {

    public init() {}

    public typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)

    /// Run the assessment. Pure w.r.t. the injected `runCommand`, so it is fully
    /// unit-testable without touching the real `spctl`/`codesign`.
    public func assess(
        bundleURL: URL = Bundle.main.bundleURL,
        runCommand: CommandRunner = NotarizationChecker.defaultRunner
    ) -> NotarizationStatus {
        // Verbose assessment; the `source=` line only appears with -vvv.
        let spctl = runCommand("/usr/sbin/spctl", ["-a", "-vvv", "-t", "exec", bundleURL.path])
        let accepted = spctl.status == 0
        let source = Self.firstLine(spctl.output, prefix: "source=")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let codesign = runCommand("/usr/bin/codesign", ["-dv", bundleURL.path])
        let identity = Self.firstLine(codesign.output, prefix: "Authority=")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return NotarizationStatus(
            accepted: accepted,
            source: source,
            identity: identity,
            codesignAccepted: codesign.status == 0
        )
    }

    /// The default runner: executes the tool, discarding nothing and returning
    /// the termination status plus combined stdout/stderr.
    public static func defaultRunner(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (Int32.max, "")
        }
    }

    /// Extract the first line that begins with `prefix` (e.g. "source=" / "Authority=").
    static func firstLine(_ output: String, prefix: String) -> String {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return ""
    }
}
