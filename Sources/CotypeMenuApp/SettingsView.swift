import SwiftUI
import AppKit
import CotypeCore
import CotypeMacOS

/// The fixed sidebar sections of the Cotype settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case general = "General"
    case context = "Context"
    case personalization = "Personalization"
    case shortcuts = "Shortcuts"
    case appSettings = "App Settings"
    case statistics = "Statistics"
    case privacyData = "Privacy & Data"
    case about = "About"
    case contactSupport = "Contact Support"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .setup: return "gearshape"
        case .general: return "slider.horizontal.3"
        case .context: return "text.cursor"
        case .personalization: return "person.crop.circle"
        case .shortcuts: return "keyboard"
        case .appSettings: return "app.badge"
        case .statistics: return "chart.bar"
        case .privacyData: return "hand.raised"
        case .about: return "info.circle"
        case .contactSupport: return "envelope"
        }
    }

    /// The one-line purpose shown under the pane title.
    var purpose: String {
        switch self {
        case .setup: return "Connect Cotype to Local Models and confirm permissions."
        case .general: return "Behavior and the model used for completions."
        case .context: return "Choose what Cotype reads around the cursor when completing."
        case .personalization: return "Learn from your accept and reject signals."
        case .shortcuts: return "The keys that drive the completion loop."
        case .appSettings: return "Per-app completions and system prompt overrides."
        case .statistics: return "How Cotype is being used."
        case .privacyData: return "What Cotype reads, stores, and sends. Inference stays on this Mac."
        case .about: return "Cotype"
        case .contactSupport: return "Report a bug or ask a question."
        }
    }

}

/// Lets a pane publish its "reset to defaults" action to the window footer, so
/// the affordance lives in one place instead of inside the cards.
@MainActor
final class SettingsResetCoordinator: ObservableObject {
    @Published private(set) var title: String?
    private var action: (() -> Void)?

    func register(_ title: String, _ action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    func clear() {
        title = nil
        action = nil
    }

    func run() {
        action?()
    }
}

/// A card row group: one uppercase `section` label over a card whose rows are
/// split by dividers. Kept as the old name so panes read unchanged.
struct SettingsCard<Content: View>: View {
    var title: String?
    /// A short right-hand fact on the card's header row ("4 of 5 complete").
    var counter: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        SlateCard(section: title, counter: counter, footnote: subtitle) {
            content
        }
    }
}

/// A labeled control row: label on the left, control on the right.
struct SettingsRow<Control: View>: View {
    var title: String
    var caption: String?
    @ViewBuilder var control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        SlateRow(title: title, detail: caption) {
            control
        }
    }
}

/// The root settings window: the shared Slate shell — a 220 px rail on the
/// sunken ground, a 60 px pane header, cards on the window ground, and a
/// footer well.
struct SettingsView: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var completionController: CompletionController
    let personalization: PersonalizationStore
    let overrides: AppOverridesStore
    @ObservedObject var updater: SparkleUpdateController

    @State private var selection: SettingsSection
    @StateObject private var reset = SettingsResetCoordinator()
    @StateObject private var localModels = LocalModelsMonitor()

    init(
        engineManager: EngineManager,
        completionController: CompletionController,
        personalization: PersonalizationStore,
        overrides: AppOverridesStore,
        updater: SparkleUpdateController,
        initialSection: SettingsSection = .setup
    ) {
        self.engineManager = engineManager
        self.completionController = completionController
        self.personalization = personalization
        self.overrides = overrides
        self.updater = updater
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            pane
        }
        .background(House.ColorToken.surface)
        .frame(minWidth: 920, minHeight: 620)
        .environmentObject(reset)
        .background(shortcuts)
        .onAppear { localModels.start() }
        .onDisappear { localModels.stop() }
        .onChange(of: selection) { _, _ in reset.clear() }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            AppMark(symbol: "text.cursor", name: "Cotype", caption: "Settings")
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.xxl)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    RailRow(
                        symbol: section.icon,
                        title: section.title,
                        isSelected: selection == section
                    ) {
                        selection = section
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(width: House.Layout.settingsRail)
        .frame(maxHeight: .infinity)
        .background(House.ColorToken.surfaceSunken)
        .overlay(alignment: .trailing) {
            House.ColorToken.divider.frame(width: House.hairline)
        }
    }

    // MARK: - Pane

    private var pane: some View {
        VStack(spacing: 0) {
            PaneHeader(title: selection.title, purpose: selection.purpose)
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if selection == .appSettings {
            // App Settings needs a full-height split layout, so it is not wrapped
            // in the scrolling container that the other panes share.
            AppSettingsPane(personalization: personalization, overrides: overrides)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: House.Spacing.md) {
                    switch selection {
                    case .setup:
                        SetupPane(engineManager: engineManager)
                    case .general:
                        GeneralPane(engineManager: engineManager, completionController: completionController)
                    case .context:
                        ContextPane()
                    case .personalization:
                        PersonalizationPane(store: personalization, engineManager: engineManager)
                    case .shortcuts:
                        ShortcutsPane()
                    case .appSettings:
                        EmptyView()
                    case .statistics:
                        StatisticsPane(store: personalization)
                    case .privacyData:
                        PrivacyDataPane(store: personalization, completionController: completionController)
                    case .about:
                        AboutPane(engineManager: engineManager, updater: updater)
                    case .contactSupport:
                        ContactSupportPane()
                    }
                }
                .padding(House.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        FooterWell {
            FooterStatus(text: footerStatusText, tint: footerTint)
        } trailing: {
            HStack(spacing: House.Spacing.md) {
                if let title = reset.title {
                    Button { reset.run() } label: {
                        KeyHint(title: title, chord: "⌘ ⌫")
                    }
                    .buttonStyle(.plain)
                }
                KeyHint(title: "Next section", chord: "⌘ ]")
            }
        }
    }

    private var footerStatusText: String {
        let completions = completionController.completionsEnabled ? "Completions on" : "Completions off"
        let status = localModels.status
        let model: String
        if status.isConfiguredModelWarm {
            model = "\(status.configuredModelAlias) warm"
        } else if status.isReachable {
            model = "\(status.configuredModelAlias) not loaded"
        } else {
            model = "Local Models offline"
        }
        return "\(completions) · \(model)"
    }

    private var footerTint: Color {
        completionController.completionsEnabled && localModels.status.isConfiguredModelWarm
            ? House.ColorToken.success
            : House.ColorToken.danger
    }

    // MARK: - Keyboard

    /// Every section is reachable without a pointer: ⌘1…⌘9 select, ⌘] steps to
    /// the next section, ⌘⌫ runs the current pane's reset.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(SettingsSection.allCases.prefix(9).enumerated()), id: \.offset) { index, section in
                Button("") { selection = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { advance() }
                .keyboardShortcut("]", modifiers: .command)
            Button("") { reset.run() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(reset.title == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func advance() {
        let all = SettingsSection.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        selection = all[(index + 1) % all.count]
    }
}

// MARK: - Formatting helpers

func formatFileSize(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: "%.1f %@", value, units[index])
}

func appDisplayName(for bundleID: String) -> String {
    if bundleID == AppOverridesStore.defaultKey { return "Global Defaults" }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
       let bundle = Bundle(url: url),
       let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
        return name
    }
    return bundleID
}
