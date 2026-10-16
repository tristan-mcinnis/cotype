import SwiftUI
import AppKit
import Combine
import CotypeCore
import CotypeMacOS

// The menu-bar surface. The old NSMenu is replaced by a 300 px Slate panel: the
// same glass as every other floating Cotype panel, a header with the live model
// status and an ink completions toggle, action rows with outlined key caps, and
// a footer well. Every action the menu had is still here, the rarer ones moved
// into a second group of rows. The row and window plumbing is the shared kit in
// MenuBarPanel.swift.

/// The panel's live state. The delegate pushes it in; the view reads it.
@MainActor
final class MenuPanelModel: ObservableObject {
    @Published var completionsEnabled = true
    @Published var statusLine = ""
    @Published var isReady = false
    @Published var phaseLine = ""
    @Published var errorLine: String?
    @Published var actions: [PanelAction] = []
    @Published var moreActions: [PanelAction] = []
    @Published var selection: Int = 0

    /// Toggling completions is owned by the delegate.
    var onToggleCompletions: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onClose: () -> Void = {}

    /// Every selectable row, in keyboard order: the action rows, the rarer
    /// rows, then the two footer actions.
    var selectableActions: [PanelAction] {
        actions + moreActions + [
            PanelAction(id: "settings", glyph: "gearshape", title: "Settings", chord: "⌘,", run: onOpenSettings),
            PanelAction(id: "quit", glyph: "power", title: "Quit", chord: "⌘Q", run: onQuit),
        ]
    }

    func moveSelection(by delta: Int) {
        let rows = selectableActions
        guard !rows.isEmpty else { return }
        var next = selection
        for _ in 0..<rows.count {
            next = (next + delta + rows.count) % rows.count
            if rows[next].isEnabled { break }
        }
        selection = next
    }

    func runSelection() {
        let rows = selectableActions
        guard rows.indices.contains(selection), rows[selection].isEnabled else { return }
        rows[selection].run()
    }

    func escape() {
        onClose()
    }
}

struct MenuBarPanelView: View {
    @ObservedObject var model: MenuPanelModel

    /// The panel width from the mockup.
    static let width: CGFloat = 300

    var body: some View {
        HouseGlass(radius: House.Radius.lg) {
            VStack(spacing: 0) {
                header
                SlateDivider()
                rows
                FooterWell {
                    footerButton(index: model.actions.count + model.moreActions.count,
                                 title: "Settings", chord: "⌘ ,", run: model.onOpenSettings)
                } trailing: {
                    footerButton(index: model.actions.count + model.moreActions.count + 1,
                                 title: "Quit", chord: "⌘ Q", run: model.onQuit)
                }
            }
        }
        .frame(width: Self.width)
        .padding(House.Spacing.md)
    }

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            IconTile(symbol: "text.cursor")
            VStack(alignment: .leading, spacing: 1) {
                Text("Cotype")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                HStack(spacing: House.Spacing.xxs) {
                    StatusDot(tint: model.isReady ? House.ColorToken.success : House.ColorToken.danger)
                    Text(model.statusLine)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: House.Spacing.xs)
            InkSwitch(isOn: Binding(
                get: { model.completionsEnabled },
                set: { _ in model.onToggleCompletions() }
            ))
            .accessibilityLabel("Enable completions")
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.sm)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                row(action, index: index)
            }
            if !model.moreActions.isEmpty {
                SlateDivider().padding(.vertical, House.Spacing.xxs)
                ForEach(Array(model.moreActions.enumerated()), id: \.element.id) { index, action in
                    row(action, index: model.actions.count + index)
                }
            }
            if let error = model.errorLine, !error.isEmpty {
                Text(error)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, House.Spacing.sm)
                    .padding(.top, House.Spacing.xxs)
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .padding(.vertical, House.Spacing.xs)
    }

    private func row(_ action: PanelAction, index: Int) -> some View {
        PanelRow(
            action: action,
            isSelected: model.selection == index,
            onHover: { model.selection = index },
            onTap: { action.run() }
        )
    }

    private func footerButton(index: Int, title: String, chord: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            KeyHint(title: title, chord: chord)
                .padding(.horizontal, House.Spacing.xxs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(model.selection == index ? House.ColorToken.selectionFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.selection = index } }
    }
}
