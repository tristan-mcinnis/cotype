import Foundation
import ApplicationServices
import CoreGraphics
import CotypeCore

// Cotype diagnostic report.
//
// Emits a machine-readable (JSON) or human-readable report covering:
//   - app version / build / git commit / bundle id
//   - code-signing identity (as seen by codesign)
//   - installed model path / size / SHA-256 / license
//   - llama.cpp build embedded in the app
//   - TCC permission PREFLIGHT status (Accessibility / Input Monitoring /
//     event posting) read-only
//
// It deliberately never reads editor text, clipboard contents, or the
// personalization / app-overrides data files, so the report is safe to share.

private let defaultAppPath = NSHomeDirectory() + "/Applications/Cotype.app"
private let defaultModelFilename = "gemma-4-E2B-it-Q4_K_M.gguf"
private let modelSHA256 = "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8"

enum DiagFormat: String {
    case json
    case text
}

struct Arguments {
    var appPath: String = defaultAppPath
    var modelPath: String?
    var format: DiagFormat = .text
    var computeHash: Bool = false
    var llamaBuild: String = ""

    static func parse(_ args: [String]) -> Arguments? {
        var a = Arguments()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--app":
                guard i + 1 < args.count else { return nil }
                a.appPath = args[i + 1]; i += 2
            case "--model":
                guard i + 1 < args.count else { return nil }
                a.modelPath = args[i + 1]; i += 2
            case "--format":
                guard i + 1 < args.count, let f = DiagFormat(rawValue: args[i + 1]) else { return nil }
                a.format = f; i += 2
            case "--hash": a.computeHash = true; i += 1
            case "--no-hash": a.computeHash = false; i += 1
            case "--llama-build":
                guard i + 1 < args.count else { return nil }
                a.llamaBuild = args[i + 1]; i += 2
            case "--help", "-h":
                print("""
                Cotype diagnostics
                  --app <path>       Cotype.app bundle path (default: ~/Applications/Cotype.app)
                  --model <path>     GGUF path (default: auto-detect)
                  --format json|text output format (default: text)
                  --hash / --no-hash include/omit the model SHA-256 (default: omit)
                  --llama-build bNNNN override llama.cpp build number
                """)
                return nil
            default:
                return nil
            }
        }
        return a
    }
}

enum ReportError: Error { case badURL(String) }

// MARK: - Helpers

func shellSHA256(of path: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let line = String(data: data, encoding: .utf8)?
                .split(separator: " ").first else { return nil }
        return String(line)
    } catch { return nil }
}

func fileSize(of path: String) -> Int64? {
    try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
}

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

func detectModelPath(explicit: String?) -> String? {
    if let explicit, FileManager.default.fileExists(atPath: explicit) { return explicit }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    for dir in ["Library/Application Support/Cotype/Models", "Models/gguf", "models"] {
        let url = home.appendingPathComponent(dir + "/" + defaultModelFilename)
        if fm.fileExists(atPath: url.path) { return url.path }
    }
    return nil
}

func llamaFrameworkVersion(totalPath: String) -> String {
    let frameworks = (totalPath as NSString).appendingPathComponent("Contents/Frameworks/llama.framework/Resources/Info.plist")
    guard let bundle = Bundle(path: frameworks) else { return "" }
    return info(bundle, "CFBundleShortVersionString")
}

// MARK: - Report

func buildReport(_ args: Arguments) -> [String: Any] {
    let appBundle = Bundle(path: args.appPath)
    let modelPath = detectModelPath(explicit: args.modelPath)
    let hasModel = modelPath.map(FileManager.default.fileExists(atPath:)) ?? false

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

    // Model.
    var model: [String: Any] = [:]
    model["installed"] = hasModel
    model["path"] = modelPath ?? ""
    model["filename"] = modelPath.map { ($0 as NSString).lastPathComponent } ?? defaultModelFilename
    model["size_bytes"] = modelPath.flatMap(fileSize(of:)) ?? 0
    model["license"] = appBundle.map { info($0, "CotypeModelLicense") } ?? "Apache-2.0"
    model["expected_sha256"] = modelSHA256
    if hasModel, args.computeHash, let m = modelPath {
        model["sha256"] = shellSHA256(of: m) ?? ""
    }
    report["model"] = model

    // Engine.
    let frameworksVersion = appBundle.map { llamaFrameworkVersion(totalPath: $0.bundlePath) } ?? ""
    report["engine"] = [
        "llama_build": args.llamaBuild.isEmpty
            ? (appBundle.map { info($0, "CotypeLlamaBuild") } ?? "")
            : args.llamaBuild,
        "llama_version": frameworksVersion.isEmpty
            ? (appBundle.map { info($0, "CotypeLlamaVersion") } ?? "")
            : frameworksVersion,
        "llama_license": appBundle.map { info($0, "CotypeLlamaLicense") } ?? "MIT",
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
        line("  llama.cpp   : \(engine["llama_build"] ?? "") (\(engine["llama_version"] ?? ""))")
        line("  license     : \(engine["llama_license"] ?? "")")
    }
    if let completion = report["completion"] as? [String: Any] {
        line("Completion")
        line("  token budget: \(completion["token_budget"] ?? "?") (\(completion["token_budget_source"] ?? "?"))")
        line("  prompt style: \(completion["prompt_style"] ?? "?")")
    }
    if let model = report["model"] as? [String: Any] {
        line("Model")
        let installed = (model["installed"] as? Bool) == true
        line("  installed   : \(installed ? "yes" : "no")")
        line("  path        : \(model["path"] ?? "")")
        if let size = model["size_bytes"] as? Int64, size > 0 {
            line("  size        : \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        if let sha = model["sha256"] as? String, !sha.isEmpty {
            line("  sha256      : \(sha)")
        }
        line("  license     : \(model["license"] ?? "")")
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
