import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Reusable model status card

/// Live, read-only view of the Local Models control plane. The menu-bar
/// app owns lifecycle; Cotype only observes whether the daemon is reachable and
/// whether its configured completion alias is warm.
///
/// Refreshes are on demand: a pane's `onAppear` and the card's Refresh button.
/// There is deliberately no repeating timer, and overlapping calls share one
/// read instead of stacking GETs on the daemon.
@MainActor
final class LocalModelsMonitor: ObservableObject {
    @Published private(set) var status = LocalModelsStatus(
        configuredModelAlias: DaemonRoutedEngine.defaultModel,
        modelIDs: [],
        warmModelIDs: [],
        isReachable: false,
        error: "Checking Local Models…"
    )

    private let refresher: LocalModelsStatusRefresher
    private var refreshTask: Task<Void, Never>?
    /// Bumped on stop so a cancelled read cannot clear a newer read's handle.
    private var refreshGeneration = 0

    init(client: LocalModelsStatusClient = LocalModelsStatusClient()) {
        self.refresher = LocalModelsStatusRefresher(client: client)
    }

    /// One-shot refresh, for a pane's `onAppear`. No repeating schedule follows.
    func start() {
        refresh()
    }

    /// Cancel any in-flight read (a pane disappeared). Nothing is scheduled, so
    /// there is no timer to invalidate.
    func stop() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        Task { await refresher.cancelInFlight() }
    }

    /// Refresh the status; a call while a read is in flight is a no-op.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let refresher = self.refresher
        refreshTask = Task { [weak self] in
            let next = await refresher.refresh()
            guard let self, generation == self.refreshGeneration else { return }
            self.refreshTask = nil
            guard !Task.isCancelled else { return }
            self.status = next
        }
    }
}

struct LocalModelsStatusCard: View {
    @ObservedObject var monitor: LocalModelsMonitor

    private var status: LocalModelsStatus { monitor.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateRow(title: statusText) {
                HStack(spacing: House.Spacing.sm) {
                    StatusPill(
                        text: status.isConfiguredModelWarm ? "Warm" : "Not ready",
                        tint: status.isConfiguredModelWarm ? House.ColorToken.success : House.ColorToken.danger
                    )
                    Button("Refresh") { monitor.refresh() }
                        .buttonStyle(HouseChipButtonStyle())
                }
            }
            SlateDivider()
            SlateBlock {
                SlateInfoRow(title: "System", value: "Local Models menu bar")
                SlateInfoRow(title: "Model alias", value: status.configuredModelAlias, monospaced: true)
                SlateInfoRow(title: "Registry", value: "~/Models/models.json", monospaced: true)
                if let endpoint = status.endpoint(for: status.configuredModelAlias) {
                    SlateInfoRow(title: "Endpoint", value: endpoint, monospaced: true)
                }
            }
            SlateDivider()
            SlateBlock {
                SlateProse("Load or unload this model from the Local Models menu-bar icon. Cotype never downloads or keeps a second copy of the weights.", tertiary: true)
            }
        }
    }

    private var statusText: String {
        if !status.isReachable { return "Local Models daemon is not reachable" }
        if !status.isConfiguredModelRegistered { return "\(status.configuredModelAlias) is not registered" }
        if !status.isConfiguredModelWarm { return "\(status.configuredModelAlias) is not loaded" }
        return "\(status.configuredModelAlias) is loaded and ready"
    }
}

/// A small two-column info row used across the model cards. Label on the left,
/// value on the right, aligned to the first text baseline so rows line up.
struct ModelInfoRow: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        SlateInfoRow(title: title, value: value, monospaced: monospaced)
    }
}

/// Shows the installed model's status, path, size, and a Reveal-in-Finder plus
/// a Load/Unload control. Shared by the Setup and General panes.
///
/// The load state and the action button are deliberately coupled so the copy is
/// unambiguous: the status text names exactly what is happening and the button
/// label names exactly what it will do.
struct ModelStatusRow: View {
    @ObservedObject var engineManager: EngineManager
    @AppStorage(DaemonRoutedEngine.enabledKey) private var useDaemon = true
    @StateObject private var localModels = LocalModelsMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateRow(
                title: "Use the Local Models menu bar",
                detail: useDaemon
                    ? "Local Models owns the registry, weights, and load/unload lifecycle. Cotype streams from its warm completion model without making another copy."
                    : "Legacy standalone mode loads a private model inside Cotype. Use this only when Local Models is unavailable."
            ) {
                InkSwitch(isOn: $useDaemon)
            }
            SlateDivider()

            if useDaemon {
                LocalModelsStatusCard(monitor: localModels)
            } else {
                SlateRow(title: statusText) {
                    statusBadge
                }

                if let path = engineManager.modelPath {
                    SlateDivider()
                    SlateBlock {
                        SlateInfoRow(title: "Model file", value: (path as NSString).lastPathComponent)
                        SlateInfoRow(title: "Size", value: formatFileSize(engineManager.modelSize))
                        SlateInfoRow(title: "Location", value: path)
                        Button("Reveal in Finder") { Self.revealInFinder(path) }
                            .buttonStyle(HouseLinkButtonStyle())
                    }
                } else {
                    SlateDivider()
                    SlateBlock {
                        SlateProse("No standalone model is available.", tertiary: true)
                    }
                }

                SlateDivider()
                SlateRow {
                    loadButton
                }
            }
        }
        .onAppear { localModels.start() }
        .onDisappear { localModels.stop() }
    }

    @ViewBuilder
    private var loadButton: some View {
        switch engineManager.status {
        case .idle:
            Button("Load Model") { engineManager.loadIfNeeded() }
                .buttonStyle(HouseChipButtonStyle())
                .disabled(engineManager.isBusy)
        case .loading:
            Button("Loading…") {}
                .buttonStyle(HouseChipButtonStyle())
                .disabled(true)
        case .ready:
            Button("Unload Model") { engineManager.unload() }
                .buttonStyle(HouseChipButtonStyle())
                .disabled(engineManager.isBusy)
        case .failed:
            if engineManager.modelPath == nil {
                Button("Install the model in Setup") {}
                    .buttonStyle(HouseChipButtonStyle())
                    .disabled(true)
            } else {
                Button("Retry Load") { engineManager.loadIfNeeded() }
                    .buttonStyle(HouseChipButtonStyle())
                    .disabled(engineManager.isBusy)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch engineManager.status {
        case .idle:
            StatusPill(text: "Not loaded", tint: House.ColorToken.textTertiary)
        case .loading:
            ProgressView().controlSize(.small)
        case .ready:
            StatusPill(text: "Ready", tint: House.ColorToken.success)
        case .failed:
            StatusPill(text: "Failed", tint: House.ColorToken.danger)
        }
    }

    private var statusText: String {
        switch engineManager.status {
        case .idle: return "Not loaded — it loads automatically on the first completion"
        case .loading: return "Loading model…"
        case .ready: return "Ready"
        case .failed(let message):
            return engineManager.modelPath == nil
                ? "No model installed — complete Setup to download it"
                : "Failed to load: \(message)"
        }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

