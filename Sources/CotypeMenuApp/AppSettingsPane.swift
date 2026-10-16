import SwiftUI
import AppKit
import CotypeCore

/// Functional per-app configuration backed by `AppOverridesStore` and populated
/// by `PersonalizationStore` sample counts.
///
/// Left column: searchable list of apps (sample counts + override entries).
/// Right column: per-app enable toggle and system-prompt override, persisted
/// through `AppOverridesStore`.
struct AppSettingsPane: View {
    @StateObject private var model: AppSettingsModel
    @State private var draftPrompt = ""
    @EnvironmentObject private var reset: SettingsResetCoordinator

    init(personalization: PersonalizationStore, overrides: AppOverridesStore) {
        _model = StateObject(wrappedValue: AppSettingsModel(store: overrides, personalization: personalization))
    }

    var body: some View {
        HStack(spacing: 0) {
            appList
            House.ColorToken.divider.frame(width: House.hairline)
            if let entry = model.selected {
                detail(entry)
                    .id(entry.bundleID)
            } else {
                Text("Select an app")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 460)
    }

    // MARK: - Left column

    private var appList: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            Text("Apps".uppercased())
                .font(House.TypeToken.section)
                .tracking(House.TypeToken.Tracking.section)
                .foregroundStyle(House.ColorToken.textTertiary)
                .padding(.horizontal, House.Spacing.sm)

            HStack(spacing: House.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: House.TypeToken.Size.meta))
                    .foregroundStyle(House.ColorToken.textTertiary)
                TextField("Search apps", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(House.TypeToken.meta)
            }
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
            .padding(.horizontal, House.Spacing.sm)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.filtered) { entry in
                        AppRow(
                            entry: entry,
                            isSelected: model.selected?.bundleID == entry.bundleID
                        ) {
                            model.selected = entry
                        }
                    }
                }
                .padding(.horizontal, House.Spacing.xs)
            }
        }
        .frame(width: 280)
        .padding(.vertical, House.Spacing.sm)
        .background(House.ColorToken.surfaceSunken)
    }

    // MARK: - Right column

    private func detail(_ entry: AppSettingsModel.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.md) {
                SettingsCard(title: entry.displayName, subtitle: entry.bundleID) {
                    StatRow(title: "Completion samples", value: "\(entry.count)")
                }

                if entry.isBuiltInSensitive {
                    SettingsCard(title: "Completions") {
                        SlateRow(
                            title: "This is a sensitive app. Cotype never completes or logs here — this cannot be overridden.",
                            detail: appDisplayName(for: entry.bundleID)
                        ) {
                            StatusPill(text: "Locked", tint: House.ColorToken.warning)
                        }
                    }
                } else {
                    SettingsCard(title: "Completions") {
                        let enabledBinding = Binding<Bool>(
                            get: { self.model.enabled(for: entry.bundleID) },
                            set: { self.model.setEnabled(entry.bundleID, $0) }
                        )
                        SlateRow(
                            title: "Enable completions for this app",
                            detail: entry.enabled == nil
                                ? "Inheriting the global default. Toggle to set an explicit value."
                                : nil
                        ) {
                            InkSwitch(isOn: enabledBinding)
                        }
                    }
                }

                if entry.isBuiltInSensitive {
                    SettingsCard(title: "System prompt override", subtitle: "Not available for sensitive apps") {
                        SlateBlock {
                            SlateProse("System prompt overrides are never applied to built-in sensitive apps, because Cotype does not complete here.", tertiary: true)
                        }
                    }
                } else {
                    SettingsCard(title: "System prompt override") {
                        SlateBlock {
                            TextEditor(text: $draftPrompt)
                                .font(House.TypeToken.code)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 120, maxHeight: 220)
                                .padding(House.Spacing.xs)
                                .background(
                                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                        .fill(House.ColorToken.well)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                        .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                                )
                        }
                        SlateDivider()
                        SlateRow(title: "Leave empty to use the default system prompt.") {
                            Button("Save") {
                                model.setSystemPrompt(entry.bundleID, draftPrompt.isEmpty ? nil : draftPrompt)
                            }
                            .buttonStyle(HouseChipButtonStyle())
                        }
                    }
                }

                SettingsCard(title: "Note") {
                    SlateBlock {
                        SlateProse("Overrides apply the next time Cotype completes in this app. If an app is not listed, it has not been used with Cotype yet.", tertiary: true)
                    }
                }
            }
            .padding(House.Spacing.lg)
        }
        .onAppear {
            draftPrompt = entry.systemPrompt ?? ""
            registerReset(entry)
        }
        .onChange(of: entry.bundleID) { _, _ in
            draftPrompt = entry.systemPrompt ?? ""
            registerReset(entry)
        }
    }

    /// The pane's "Reset to defaults" lives in the window footer (⌘⌫). For App
    /// Settings it clears the selected app's override, exactly as the old
    /// in-card "Reset to default" button did.
    private func registerReset(_ entry: AppSettingsModel.Entry) {
        guard !entry.isBuiltInSensitive else {
            reset.clear()
            return
        }
        reset.register("Reset to default") {
            model.clearOverride(entry.bundleID)
            draftPrompt = ""
        }
    }
}

/// A row in the app list.
private struct AppRow: View {
    let entry: AppSettingsModel.Entry
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: House.Spacing.xs) {
                IconTile(symbol: "app.dashed", size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(entry.bundleID)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: House.Spacing.xxs)
                if entry.count > 0 {
                    Text("\(entry.count)")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .padding(.horizontal, House.Spacing.xs)
                        .frame(height: House.Control.keyCap)
                        .background(
                            RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                                .fill(House.ColorToken.chipFill)
                        )
                }
                if entry.enabled == false {
                    StatusDot(tint: House.ColorToken.warning)
                        .accessibilityLabel("Paused")
                }
                if entry.isBuiltInSensitive {
                    StatusDot(tint: House.ColorToken.danger)
                        .accessibilityLabel("Sensitive")
                }
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: House.Control.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
        if isSelected {
            shape
                .fill(House.ColorToken.surfaceRaised)
                .overlay(shape.strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline))
                .houseShadow(House.Shadow.selection, dark: scheme == .dark)
        } else if isHovering {
            shape.fill(House.ColorToken.hoverFill)
        } else {
            shape.fill(Color.clear)
        }
    }
}

// MARK: - View model

/// Wraps `AppOverridesStore`. `AppOverridesStore` is not observable, so this
/// publishes a computed snapshot of apps and re-reads after every mutation.
@MainActor
final class AppSettingsModel: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let bundleID: String
        let displayName: String
        let count: Int
        var enabled: Bool?
        var systemPrompt: String?
        /// Built-in sensitive apps are never completed or logged, and cannot be
        /// re-enabled — an override here would be misleading.
        var isBuiltInSensitive: Bool
        var id: String { bundleID }
    }

    @Published var searchText = ""
    @Published private(set) var entries: [Entry] = []
    @Published var selected: Entry?

    private let store: AppOverridesStore
    private let personalization: PersonalizationStore

    init(store: AppOverridesStore, personalization: PersonalizationStore) {
        self.store = store
        self.personalization = personalization
        reload()
    }

    var filtered: [Entry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    func enabled(for bundleID: String) -> Bool {
        entries.first(where: { $0.bundleID == bundleID })?.enabled ?? true
    }

    func reload() {
        let samples = personalization.samples()
        var counts: [String: Int] = [:]
        for sample in samples { counts[sample.appIdentifier, default: 0] += 1 }

        var bundleIDs = Set(counts.keys)
        bundleIDs.insert(AppOverridesStore.defaultKey)
        bundleIDs.formUnion(store.allKeys())

        entries = bundleIDs
            .map { id in
                let override = store.rawOverride(for: id) ?? AppOverride()
                return Entry(
                    bundleID: id,
                    displayName: appDisplayName(for: id),
                    count: counts[id] ?? 0,
                    enabled: override.enabled,
                    systemPrompt: override.systemPrompt,
                    isBuiltInSensitive: id != AppOverridesStore.defaultKey
                        && SensitiveContextDetector.isBuiltInSensitive(id)
                )
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        if let selected, let match = entries.first(where: { $0.bundleID == selected.bundleID }) {
            self.selected = match
        } else {
            selected = entries.first
        }
    }

    // A single shared model is used for every app. Per-app settings therefore
    // cover only the controls the runtime can genuinely honor.
    func setEnabled(_ bundleID: String, _ enabled: Bool) {
        let base = store.rawOverride(for: bundleID) ?? AppOverride()
        store.setOverride(AppOverride(enabled: enabled, systemPrompt: base.systemPrompt), for: bundleID)
        reload()
    }

    func setSystemPrompt(_ bundleID: String, _ prompt: String?) {
        let base = store.rawOverride(for: bundleID) ?? AppOverride()
        store.setOverride(AppOverride(enabled: base.enabled, systemPrompt: prompt), for: bundleID)
        reload()
    }

    func clearOverride(_ bundleID: String) {
        store.removeOverride(for: bundleID)
        reload()
    }

}
