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
    private var cancellationTask: Task<Void, Never>?
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
        let previousCancellation = cancellationTask
        let refresher = self.refresher
        cancellationTask = Task {
            await previousCancellation?.value
            await refresher.cancelInFlight()
        }
    }

    /// Refresh the status; a call while a read is in flight is a no-op.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let refresher = self.refresher
        let cancellation = cancellationTask
        refreshTask = Task { [weak self] in
            // A rapid disappear/appear must retire the old read before the
            // new one starts, or delayed stop work could cancel the new read.
            await cancellation?.value
            guard !Task.isCancelled else { return }
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
                        text: status.readiness.isReady ? "Warm" : "Not ready",
                        tint: status.readiness.isReady ? House.ColorToken.success : House.ColorToken.danger
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
        status.readiness.summary(modelAlias: status.configuredModelAlias)
    }
}

/// The Local Models status card with its own monitor. Shared by the Setup
/// and General panes.
struct ModelStatusRow: View {
    @StateObject private var localModels = LocalModelsMonitor()

    var body: some View {
        LocalModelsStatusCard(monitor: localModels)
            .onAppear { localModels.start() }
            .onDisappear { localModels.stop() }
    }
}

