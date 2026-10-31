import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - About

struct AboutPane: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var updater: SparkleUpdateController
    @State private var notarization: NotarizationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
            SettingsCard(title: "Cotype") {
                SlateBlock {
                    AppMark(symbol: "text.cursor", name: "Cotype", caption: "Version \(Self.version)")
                }
                SlateDivider()
                StatRow(title: "Engine", value: "llama.cpp \(Self.info("CotypeLlamaBuild", "b10665"))")
                SlateDivider()
                StatRow(title: "Model", value: engineManager.modelPath.map { ($0 as NSString).lastPathComponent } ?? "Not installed")
                SlateDivider()
                StatRow(title: "Model license", value: Self.info("CotypeModelLicense", "Apache-2.0"))
                SlateDivider()
                StatRow(title: "Local inference", value: "Metal")
                SlateDivider()
                StatRow(title: "Build mode", value: Self.buildMode)
                SlateDivider()
                StatRow(title: "Signing", value: notarization?.identity ?? Self.signingIdentity)
                SlateDivider()
                StatRow(title: "Notarized", value: notarizedLabel)
                SlateDivider()
                StatRow(title: "Architecture", value: Self.info("CotypeArchitecture", "arm64"))
            }
            SettingsCard(title: "Updates") {
                SlateRow(title: "Automatically check for updates") {
                    InkSwitch(isOn: $updater.automaticallyChecksForUpdates, enabled: updater.isEnabled)
                }
                SlateDivider()
                SlateRow(title: updateStatusText, minHeight: 38) {
                    Button("Check for Updates") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(HouseChipButtonStyle())
                    .disabled(!updater.isEnabled)
                }
                SlateDivider()
                SlateBlock {
                    SlateProse("Updates are verified and installed by Sparkle (Ed25519-signed appcast + SHA-256 artifact verification).", tertiary: true)
                    SlateProse("Network: when a release feed is configured, checking for updates contacts the feed URL. Cotype sends no system profile and downloads an update only after you approve it in Sparkle's UI. No completion text, settings, or model data are sent.", tertiary: true)
                }
            }
            SettingsCard(title: "Credits") {
                SlateBlock {
                    SlateProse("Built on llama.cpp and the Cotype pipeline. An open, local AI completion app for macOS.")
                    if notarization?.notarized == true {
                        SlateProse("This is a notarized Developer ID build with Hardened Runtime, safe for public distribution.")
                    } else {
                        SlateProse("This build is Apple Development / ad-hoc signed and not notarized. See docs/RELEASE.md for the opt-in Developer ID + notarization path.")
                    }
                }
            }
        }
        // Notarization is a real Gatekeeper assessment, run off the UI thread.
        .task {
            let status = await Task.detached(priority: .utility) {
                NotarizationChecker().assess(bundleURL: Bundle.main.bundleURL)
            }.value
            notarization = status
        }
    }

    var notarizedLabel: String {
        guard let status = notarization else { return "Checking…" }
        if status.notarized { return "Yes — notarized Developer ID build" }
        if status.isDeveloperID { return "No — Developer ID release candidate (not notarized)" }
        return "No — not notarized"
    }

    var updateStatusText: String {
        if updater.isEnabled {
            return "Updater ready (Sparkle). Feed: \(Self.info("SUFeedURL", "unknown"))"
        }
        return "This build has no Sparkle update feed configured; updates are unavailable."
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let v, let b { return "\(v) (\(b))" }
        return v ?? "0.1.0"
    }

    static func info(_ key: String, _ fallback: String) -> String {
        (Bundle.main.infoDictionary?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    static var buildMode: String {
        let raw = info("CotypeBuildMode", "development")
        return raw.capitalized
    }

    static var signingIdentity: String {
        let raw = info("CotypeSigningIdentity", "Apple Development / ad-hoc")
        return raw
    }
}

