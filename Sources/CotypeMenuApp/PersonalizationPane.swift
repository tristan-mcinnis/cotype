import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Personalization

struct PersonalizationPane: View {
    let store: PersonalizationStore

    // Content logging is OFF by default. Content-free, bounded usage counters
    // are still recorded as documented in Privacy & Data.
    @AppStorage("learnFromFeedback") private var learnFromFeedback = false
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
            SettingsCard(title: "Learning", subtitle: "Sentences you write and accept shape your suggestions. They stay on this Mac.") {
                SlateRow(title: "Learn from what I write") {
                    InkSwitch(isOn: $learnFromFeedback)
                }
                SlateDivider()
                SlateRow(title: "Samples recorded") {
                    Text("\(store.count)")
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
                SlateDivider()
                SlateRow {
                    Button("Clear all samples") {
                        store.clear()
                        refresh += 1
                    }
                    .buttonStyle(HouseChipButtonStyle(destructive: true))
                }
            }
            SettingsCard(title: "Recent samples", subtitle: "Newest first") {
                let samples = Array(store.samples().prefix(8))
                if samples.isEmpty {
                    SlateBlock {
                        SlateProse("No samples recorded yet.", tertiary: true)
                    }
                } else {
                    ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                        if index > 0 { SlateDivider() }
                        SlateRow(
                            title: appDisplayName(for: sample.appIdentifier),
                            detail: String((sample.outcome == .written ? sample.prefix : sample.completion).prefix(120)),
                            minHeight: 38
                        ) {
                            HStack(spacing: House.Spacing.xs) {
                                StatusDot(tint: outcomeTint(for: sample.outcome))
                                Text(outcomeLabel(for: sample.outcome))
                                    .font(House.TypeToken.meta)
                                    .foregroundStyle(House.ColorToken.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        .id(refresh)
    }
}

