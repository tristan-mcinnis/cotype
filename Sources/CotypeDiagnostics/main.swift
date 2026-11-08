import Foundation
import ApplicationServices
import CoreGraphics
import CotypeCore

// Cotype diagnostic report.
//
// Emits a machine-readable (JSON) or human-readable report covering:
//   - app version / build / git commit / bundle id
//   - code-signing identity (as seen by codesign)
//   - the Local Models model alias completions use
//   - TCC permission PREFLIGHT status (Accessibility / Input Monitoring /
//     event posting) read-only
//
// It deliberately never reads editor text, clipboard contents, or the
// personalization / app-overrides data files, so the report is safe to share.

private let defaultAppPath = NSHomeDirectory() + "/Applications/Cotype.app"

enum DiagFormat: String {
    case json
    case text
}

struct Arguments {
    var appPath: String = defaultAppPath
    var format: DiagFormat = .text

    static func parse(_ args: [String]) -> Arguments? {
        var a = Arguments()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--app":
                guard i + 1 < args.count else { return nil }
                a.appPath = args[i + 1]; i += 2
            case "--format":
                guard i + 1 < args.count, let f = DiagFormat(rawValue: args[i + 1]) else { return nil }
                a.format = f; i += 2
            case "--help", "-h":
                print("""
                Cotype diagnostics
                  --app <path>       Cotype.app bundle path (default: ~/Applications/Cotype.app)
                  --format json|text output format (default: text)
                """)
                return nil
            default:
                return nil
            }
        }
        return a
    }
}

// MARK: - Helpers

func info(_ bundle: Bundle, _ key: String) -> String {
    (bundle.object(forInfoDictionaryKey: key) as? String) ?? ""
}

func codesignInfo(of path: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["-dv", "--verbose=4", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // codesign -dv prints the certificate chain as repeated Authority= lines;
        // report only those (the signing identity) and any notarization markers.
        let authorities = lines.filter { $0.hasPrefix("Authority=") }
        return authorities.joined(separator: "\n")
    } catch { return "" }
}

func permissionReport() -> [(name: String, granted: Bool)] {
    [
        ("Accessibility", AXIsProcessTrusted()),
        ("Input Monitoring", CGPreflightListenEventAccess()),
        ("Event posting (paste)", CGPreflightPostEventAccess()),
    ]
}

// MARK: - Report

func buildReport(_ args: Arguments) -> [String: Any] {
    let appBundle = Bundle(path: args.appPath)

    var report: [String: Any] = [:]

    // App / build metadata.
    var app: [String: Any] = [:]
    app["bundle_id"] = appBundle.map { info($0, "CFBundleIdentifier") } ?? ""
    app["name"] = appBundle.map { info($0, "CFBundleName") } ?? "Cotype"
    app["version"] = appBundle.map { info($0, "CFBundleShortVersionString") } ?? ""
    app["build"] = appBundle.map { info($0, "CFBundleVersion") } ?? ""
    app["git_commit"] = appBundle.map { info($0, "CotypeBuildGitCommit") } ?? ""
    app["build_mode"] = appBundle.map { info($0, "CotypeBuildMode") } ?? ""
    app["build_date"] = appBundle.map { info($0, "CotypeBuildDate") } ?? ""
    app["bundle_present"] = appBundle != nil
    app["path"] = args.appPath
    report["app"] = app

    // Signing.
    let sig = codesignInfo(of: args.appPath)
    report["signing"] = [
        "info": sig.isEmpty ? "not signed" : sig,
    ]

    // Completion policy. Read from the app's own preference domain, so the
    // reported budget is the number its next request will carry.
    let bundleID = (app["bundle_id"] as? String) ?? ""
    let domain = bundleID.isEmpty ? "com.tristan.cotype" : bundleID
    let appDefaults = UserDefaults(suiteName: domain) ?? .standard
    let budget = TokenBudget.effective(appDefaults)
    let budgetSource: String
    switch budget.source {
    case .automatic(let length): budgetSource = "auto (\(length.rawValue))"
    case .explicitOverride: budgetSource = "custom"
    }
    report["engine"] = [
        "name": "Local Models",
        "model": appDefaults.string(forKey: "localModelsDaemonModel") ?? "gemma-it",
    ]
    report["completion"] = [
        "token_budget": budget.tokens,
        "token_budget_source": budgetSource,
        "suggestion_length": SuggestionLength.current(appDefaults).rawValue,
        "prompt_style": PromptStyle.current(appDefaults).rawValue,
    ]

    // Permissions preflight (read-only).
    report["permissions"] = permissionReport().map {
        ["name": $0.name, "granted": $0.granted]
    }

    // Guards so a diagnostic report never carries sensitive content.
    report["sensitive_content"] = "omitted"
    report["personalization_stored"] = "not inspected"
    return report
}

func renderText(_ report: [String: Any]) -> String {
    var out: [String] = []
    func line(_ s: String) { out.append(s) }

    line("Cotype Diagnostics")
    line("===================")
    if let app = report["app"] as? [String: Any] {
        line("App")
        line("  bundle id   : \(app["bundle_id"] ?? "")")
        line("  version     : \(app["version"] ?? "") (\(app["build"] ?? ""))")
        line("  git commit  : \(app["git_commit"] ?? "")")
        line("  build mode  : \(app["build_mode"] ?? "")")
        line("  build date  : \(app["build_date"] ?? "")")
        line("  bundle path : \(app["path"] ?? "")")
    }
    if let sig = report["signing"] as? [String: Any], let infoStr = sig["info"] as? String {
        line("Signing")
        let brief = infoStr.split(separator: "\n").map {
            $0.replacingOccurrences(of: "Authority=", with: "")
              .trimmingCharacters(in: .whitespaces)
        }
        if brief.isEmpty {
            line("  identity    : ad-hoc / not signed")
        } else {
            line("  identity    : \(brief.first ?? "unknown")")
            if brief.count > 1 { line("  chain       : \(brief.dropFirst().joined(separator: " → "))") }
        }
    }
    if let engine = report["engine"] as? [String: Any] {
        line("Engine")
        line("  name        : \(engine["name"] ?? "")")
        line("  model       : \(engine["model"] ?? "")")
    }
    if let completion = report["completion"] as? [String: Any] {
        line("Completion")
        line("  token budget: \(completion["token_budget"] ?? "?") (\(completion["token_budget_source"] ?? "?"))")
        line("  prompt style: \(completion["prompt_style"] ?? "?")")
    }
    if let perms = report["permissions"] as? [[String: Any]] {
        line("Permissions (preflight — read-only)")
        for p in perms {
            let granted = (p["granted"] as? Bool) == true
            line("  \(p["name"] ?? "") : \(granted ? "granted ✓" : "NOT granted")")
        }
    }
    line("")
    line("Sensitive content: omitted. This report contains no document text, clipboard contents, or stored samples.")
    return out.joined(separator: "\n")
}

// MARK: - Main

let args = CommandLine.arguments
guard let opts = Arguments.parse(args) else { exit(0) }

let report = buildReport(opts)
switch opts.format {
case .json:
    let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
case .text:
    print(renderText(report))
}

// The report is informational; always exit 0 unless a hard error is surfaced.
