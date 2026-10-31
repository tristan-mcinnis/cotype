import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Contact Support

struct ContactSupportPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
            SettingsCard(title: "Get help") {
                LinkRow(icon: "curlybraces", title: "File an issue", url: "https://github.com/tristan-mcinnis/cotype/issues")
                SlateDivider()
                LinkRow(icon: "doc.text", title: "Project documentation", url: "https://github.com/tristan-mcinnis/cotype#readme")
            }
        }
    }
}

struct LinkRow: View {
    var icon: String
    var title: String
    var url: String

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            IconTile(symbol: icon)
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            Spacer(minLength: House.Spacing.sm)
            Button {
                if url.hasPrefix("mailto:") {
                    NSWorkspace.shared.open(URL(string: url)!)
                } else if let link = URL(string: url) {
                    NSWorkspace.shared.open(link)
                }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
            }
            .buttonStyle(HouseChipButtonStyle())
        }
        .padding(.horizontal, House.Spacing.md)
        .padding(.vertical, House.Spacing.sm)
        .frame(minHeight: House.Control.xlarge)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
