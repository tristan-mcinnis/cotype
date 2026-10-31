import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Statistics

struct StatisticsPane: View {
    let store: PersonalizationStore
    @State private var refresh = 0

    var body: some View {
        let summary = store.usageSummary()
        let perApp = perAppBreakdown()

        VStack(alignment: .leading, spacing: House.Spacing.xl) {
            SettingsCard(title: "Usage", subtitle: "Content-free counters are kept even when feedback logging is off") {
                StatRow(title: "Shown (offered)", value: "\(summary.shown)")
                SlateDivider()
                StatRow(title: "Accepted", value: "\(summary.accepted)")
                SlateDivider()
                StatRow(title: "Dismissed", value: "\(summary.dismissed)")
                SlateDivider()
                StatRow(title: "Canceled", value: "\(summary.canceled)")
                SlateDivider()
                StatRow(title: "Failed", value: "\(summary.failed)")
                if summary.total == 0 {
                    SlateDivider()
                    SlateBlock {
                        SlateProse("No completion usage has been recorded yet.", tertiary: true)
                    }
                }
            }
            NotShownCard(snapshot: NotShownStore.shared.snapshot)
            SettingsCard(
                title: "Per app",
                subtitle: "Content-free counters; recorded even when feedback logging is off"
            ) {
                if perApp.isEmpty {
                    SlateBlock {
                        SlateProse("No completion usage recorded for any app yet.", tertiary: true)
                    }
                } else {
                    ForEach(Array(perApp.enumerated()), id: \.offset) { index, entry in
                        if index > 0 { SlateDivider() }
                        SlateRow(title: appDisplayName(for: entry.appIdentifier), minHeight: 38) {
                            Text("\(entry.shown) shown · \(entry.accepted) accepted · \(entry.dismissed) dismissed · \(entry.canceled) canceled · \(entry.failed) failed")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                        }
                    }
                }
            }
        }
        .id(refresh)
        .onAppear { refresh += 1 }
    }

    private func perAppBreakdown() -> [AppUsage] {
        store.perAppUsage()
    }
}

