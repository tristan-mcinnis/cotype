import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Privacy & Data

/// The Privacy & Data pane: what Cotype reads and stores, feedback consent,
/// retention, export, delete-all, excluded apps, write-failure visibility, and
/// a local-inference disclosure. Deliberately additive so existing sections
/// are untouched.
struct PrivacyDataPane: View {
    let store: PersonalizationStore
    @ObservedObject var completionController: CompletionController

    // Content logging is OFF by default. Content-free usage counters are still
    // stored as disclosed above and in PRIVACY.md.
    @AppStorage("learnFromFeedback") private var learnFromFeedback = false

    @State private var refresh = 0
    @State private var newExclusion = ""
    @State private var deleteResult: Bool?
    @State private var exportStatus: String?

    private let sensitiveAppNames: [String] =
        SensitiveContextDetector.builtInSensitiveApps.sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
            SettingsCard(title: "Local inference", subtitle: "Cotype uses the Local Models daemon on this Mac") {
                SlateRow(title: "Completion prompts travel only over loopback HTTP to Local Models and never leave this Mac.") {
                    StatusPill(text: "Loopback only", tint: House.ColorToken.success)
                }
                SlateDivider()
                SlateBlock {
                    SlateProse("Cotype reads the focused editor text to generate a completion. It stores feedback about a completion only when you opt in below.", tertiary: true)
                }
            }

            SettingsCard(title: "Feedback storage", subtitle: "Choose what Cotype records") {
                SlateRow(
                    title: "Store accepted and dismissed completions",
                    detail: "When off, Cotype writes no content records to disk. A small, content-free usage count is always kept so you can see how Cotype is used."
                ) {
                    InkSwitch(isOn: $learnFromFeedback)
                }

                if let warning = completionController.storageWarning {
                    SlateDivider()
                    SlateRow(title: warning) {
                        StatusDot(tint: House.ColorToken.warning)
                    }
                }

                SlateDivider()
                SlateRow(title: "Stored locally at", minHeight: 38) {
                    Text(PersonalizationStore.defaultFileURL().path)
                        .font(House.TypeToken.code)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                SlateDivider()
                StatRow(title: "Content samples on disk", value: "\(store.count)")
                SlateDivider()
                StatRow(title: "Usage events recorded", value: "\(store.usageSummary().total)")
                SlateDivider()
                SlateRow {
                    HStack(spacing: House.Spacing.xs) {
                        Button("Export stored data…") { exportData() }
                            .buttonStyle(HouseChipButtonStyle())
                        Button("Delete All Data") { confirmDeleteAll() }
                            .buttonStyle(HouseChipButtonStyle(destructive: true))
                    }
                }
                if deleteResult != nil || exportStatus != nil {
                    SlateDivider()
                    SlateBlock {
                        if let result = deleteResult {
                            SlateProse(result
                                 ? "Deleted and verified: all stored feedback was removed."
                                 : "Could not verify that the data was removed. Check the file location above.",
                                 tertiary: result)
                        }
                        if let message = exportStatus {
                            SlateProse(message, tertiary: true)
                        }
                    }
                }
            }

            SettingsCard(title: "Privacy notice", subtitle: "Local storage and network behavior") {
                SlateBlock {
                    SlateProse("Cotype reads up to 2,000 characters on each side of the caret in the current field to predict the next few words. If you turn on Visible active-window text, it also reads up to 800 characters of other text in the same window. This context is used in memory for the current prompt and is not stored. The prompt goes only over loopback HTTP to Local Models; non-local endpoints are rejected.")
                    SlateProse("Feedback about a completion (prefix and candidate) is stored only if you turn on Feedback storage. It is written to your local Application Support folder and is never uploaded. You can export or delete it at any time.")
                    SlateProse("Cotype has no analytics or telemetry. Internet access occurs only for a standalone model download you explicitly start and, in release builds, update checks you start or enable.", tertiary: true)
                }
            }

            SettingsCard(title: "Retention", subtitle: "How long recorded feedback is kept") {
                SlateBlock {
                    SlateSegmented(
                        options: [
                            (RetentionPolicy.off, "Off"),
                            (RetentionPolicy.sevenDays, "7 days"),
                            (RetentionPolicy.thirtyDays, "30 days"),
                            (RetentionPolicy.keepUntilDeleted, "Keep until deleted"),
                        ],
                        selection: retentionBinding
                    )
                    SlateProse("Turned off removes all stored feedback. Pruning runs whenever Cotype stores a new record.", tertiary: true)
                }
            }

            SettingsCard(title: "Excluded apps", subtitle: "Cotype never completes or logs in these apps (not overridable)") {
                SlateBlock {
                    Text("Sensitive apps (built-in)".uppercased())
                        .font(House.TypeToken.section)
                        .tracking(House.TypeToken.Tracking.section)
                        .foregroundStyle(House.ColorToken.textTertiary)
                    SlateProse("Cotype always refuses to complete or log in these apps. This cannot be turned off.", tertiary: true)
                }
                exclusionsList(sensitiveAppNames, removable: false)
                SlateDivider()
                SlateBlock {
                    Text("Your exclusions".uppercased())
                        .font(House.TypeToken.section)
                        .tracking(House.TypeToken.Tracking.section)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                if store.userExcludedApps.isEmpty {
                    SlateBlock {
                        SlateProse("None added yet.", tertiary: true)
                    }
                } else {
                    exclusionsList(store.userExcludedApps.sorted(), removable: true)
                }
                SlateDivider()
                SlateRow {
                    HStack(spacing: House.Spacing.xs) {
                        TextField("Bundle ID, e.g. com.example.app", text: $newExclusion)
                            .textFieldStyle(.plain)
                            .font(House.TypeToken.meta)
                            .padding(.horizontal, House.Spacing.xs)
                            .frame(height: House.Control.chip)
                            .background(
                                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                    .fill(House.ColorToken.well)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                    .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                            )
                        Button("Add") { addExclusion() }
                            .buttonStyle(HouseChipButtonStyle())
                            .disabled(newExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            SettingsCard(title: "Usage summary", subtitle: "How Cotype has been used when logging is on") {
                let summary = store.usageSummary()
                StatRow(title: "Shown (offered)", value: "\(summary.shown)")
                SlateDivider()
                StatRow(title: "Accepted", value: "\(summary.accepted)")
                SlateDivider()
                StatRow(title: "Dismissed", value: "\(summary.dismissed)")
                SlateDivider()
                StatRow(title: "Canceled", value: "\(summary.canceled)")
                SlateDivider()
                StatRow(title: "Failed", value: "\(summary.failed)")
            }
        }
        .id(refresh)
        .onAppear { refresh += 1 }
    }

    private var retentionBinding: Binding<RetentionPolicy> {
        Binding(
            get: { store.retentionPolicy },
            set: { store.setRetentionPolicy($0); deleteResult = nil; refresh += 1 }
        )
    }

    @ViewBuilder
    private func exclusionsList(_ ids: [String], removable: Bool) -> some View {
        ForEach(ids, id: \.self) { id in
            SlateRow(title: appDisplayName(for: id), minHeight: 38) {
                HStack(spacing: House.Spacing.xs) {
                    Text(id)
                        .font(House.TypeToken.code)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    if removable {
                        Button("Remove") {
                            var updated = store.userExcludedApps
                            updated.remove(id)
                            store.setUserExcludedApps(updated)
                            refresh += 1
                        }
                        .buttonStyle(HouseLinkButtonStyle(destructive: true))
                    }
                }
            }
        }
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = store.userExcludedApps
        updated.insert(trimmed)
        store.setUserExcludedApps(updated)
        newExclusion = ""
        refresh += 1
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.title = "Export Cotype feedback data"
        panel.nameFieldStringValue = "cotype-feedback.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self.store.exportData().write(to: url, options: .atomic)
                self.exportStatus = "Exported \(self.store.count) records."
            } catch {
                self.exportStatus = "Could not export: \(error.localizedDescription)"
            }
            self.refresh += 1
        }
    }

    private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all stored feedback?"
        alert.informativeText = "This permanently removes every recorded completion sample from this Mac. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            deleteResult = store.deleteAll()
            NotShownStore.shared.reset()
            refresh += 1
        } else {
            deleteResult = nil
        }
    }
}

struct NotShownCard: View {
    let snapshot: NotShownSnapshot
    private static let visibleReasons = 6

    var body: some View {
        SettingsCard(title: "Not shown", subtitle: "Why a requested completion never appeared. Counts only, no text") {
            let ranked = Array(snapshot.ranked.prefix(Self.visibleReasons))
            if ranked.isEmpty {
                SlateBlock {
                    SlateProse("Nothing has been held back yet.", tertiary: true)
                }
            } else {
                ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { SlateDivider() }
                    StatRow(title: Self.title(for: entry.key), value: "\(entry.value.count)")
                }
            }
        }
    }

    private static func title(for key: String) -> String {
        NotShownReason(rawValue: key)?.title ?? key
    }
}

struct StatRow: View {
    var title: String
    var value: String
    var body: some View {
        SlateRow(title: title, minHeight: 38) {
            Text(value)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
        }
    }
}

