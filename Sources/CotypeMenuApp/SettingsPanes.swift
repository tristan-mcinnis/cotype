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

// MARK: - Setup

/// A lightweight, always-live permission snapshot. Re-checks the Accessibility /
/// Input Monitoring grants on a timer and whenever the app becomes active, so
/// returning from System Settings updates the UI without a relaunch. This is the
/// "live refresh" that the old launch-time blocking alert could not provide.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var hasAccessibility = false
    @Published private(set) var hasInputMonitoring = false
    @Published private(set) var hasPostEventAccess = false

    var allGranted: Bool { hasAccessibility && hasInputMonitoring }

    private var timer: Timer?

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        hasAccessibility = AXIsProcessTrusted()
        hasInputMonitoring = CGPreflightListenEventAccess()
        hasPostEventAccess = CGPreflightPostEventAccess()
    }
}

/// The model acquisition card for Setup. It drives the in-app downloader and
/// shows the model's provenance and resource figures before the user commits a
/// multi-GB download, then progress / pause / resume / retry / cancel, checksum
/// verification, and finally installed status plus Remove / Reinstall.
struct ModelSetupCard: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        switch downloadManager.state {
        case .ready:
            installedView
        case .downloading, .verifying:
            downloadingView
        case .paused:
            pausedView
        case .failed(let message):
            failedView(message)
        case .idle:
            if downloadManager.isVerifiedNow {
                installedView
            } else if downloadManager.filePresent {
                foundUnverifiedView
            } else {
                idleView
            }
        }
    }

    // MARK: Found on disk but not yet verified (marker is not an integrity claim)

    private var foundUnverifiedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateRow(title: "Model found on disk — verification pending") {
                StatusPill(text: "Pending", tint: House.ColorToken.warning)
            }
            SlateDivider()
            SlateBlock {
                let spec = downloadManager.spec
                SlateInfoRow(title: "Model", value: spec.modelName)
                SlateInfoRow(title: "File", value: spec.managedFilename, monospaced: true)
                SlateProse("A model file is present but has not been verified. Cotype will run a SHA-256 check before it can be loaded.", tertiary: true)
            }
            SlateDivider()
            SlateRow {
                Button("Verify & Install") { downloadManager.start() }
                    .buttonStyle(HouseInkButtonStyle())
            }
        }
    }

    // MARK: Not yet installed

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateBlock {
                let spec = downloadManager.spec
                SlateInfoRow(title: "Model", value: spec.modelName)
                SlateInfoRow(title: "Source", value: spec.sourcePageURL)
                SlateInfoRow(title: "License", value: spec.license)
                SlateInfoRow(title: "Download size", value: formatFileSize(spec.expectedSize))
                SlateInfoRow(title: "RAM needed", value: formatFileSize(spec.ramUseBytes))
                SlateInfoRow(title: "Disk space", value: formatFileSize(spec.diskRequirementBytes))
            }
            if downloadManager.hasLegacyOnlyModel {
                SlateDivider()
                SlateBlock {
                    SlateProse("An older model is installed. Installing the current model replaces it (the old weights are removed after a verified install).")
                }
            }
            SlateDivider()
            SlateRow {
                Button("Download & Install Model") { downloadManager.start() }
                    .buttonStyle(HouseInkButtonStyle())
            }
        }
    }

    // MARK: Downloading / verifying

    private var downloadingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateRow(title: downloadManager.state == .verifying ? "Verifying model…" : "Downloading model…") {
                Text("\(Int(downloadManager.progressFraction * 100))%")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
            }
            SlateBlock {
                ProgressView(value: downloadManager.progressFraction)
                    .tint(House.ColorToken.textPrimary)
                HStack(spacing: House.Spacing.xxs) {
                    Text("\(formatFileSize(downloadManager.downloadedBytes)) of \(formatFileSize(downloadManager.totalBytes))")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                    Spacer()
                    if downloadManager.speedBytesPerSecond > 0 {
                        Text("\(formatFileSize(Int64(downloadManager.speedBytesPerSecond)))/s")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                    }
                    if let remaining = downloadManager.remainingBytes, downloadManager.state == .downloading {
                        Text("· \(formatFileSize(remaining)) left")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                    }
                }
            }
            SlateDivider()
            SlateRow {
                HStack(spacing: House.Spacing.xs) {
                    if downloadManager.state == .downloading {
                        Button("Pause") { downloadManager.pause() }
                            .buttonStyle(HouseChipButtonStyle())
                    }
                    Button("Cancel") { downloadManager.cancel() }
                        .buttonStyle(HouseChipButtonStyle(destructive: true))
                }
            }
        }
    }

    // MARK: Paused

    private var pausedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateBlock {
                SlateProse("Download paused — \(formatFileSize(downloadManager.downloadedBytes)) downloaded so far. You can resume where it left off.")
                ProgressView(value: downloadManager.progressFraction)
                    .tint(House.ColorToken.textPrimary)
            }
            SlateDivider()
            SlateRow {
                HStack(spacing: House.Spacing.xs) {
                    Button("Resume") { downloadManager.resume() }
                        .buttonStyle(HouseChipButtonStyle())
                    Button("Cancel Download") { downloadManager.cancel() }
                        .buttonStyle(HouseChipButtonStyle(destructive: true))
                }
            }
        }
    }

    // MARK: Failed

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateRow(title: "Download failed") {
                StatusPill(text: "Error", tint: House.ColorToken.danger)
            }
            SlateDivider()
            SlateBlock {
                SlateProse(message, tertiary: true)
            }
            SlateDivider()
            SlateRow {
                HStack(spacing: House.Spacing.xs) {
                    Button("Retry") { downloadManager.retry() }
                        .buttonStyle(HouseInkButtonStyle())
                    Button("Remove Partial Download") { downloadManager.cancel() }
                        .buttonStyle(HouseChipButtonStyle(destructive: true))
                }
            }
        }
    }

    // MARK: Installed

    private var installedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateRow(title: "Model installed and verified") {
                StatusPill(text: "Verified", tint: House.ColorToken.success)
            }
            SlateDivider()
            SlateBlock {
                let spec = downloadManager.spec
                SlateInfoRow(title: "Model", value: spec.modelName)
                SlateInfoRow(title: "Size", value: formatFileSize(spec.expectedSize))
                SlateInfoRow(title: "Checksum", value: downloadManager.isVerifiedNow ? "Verified (SHA-256)" : "Pending verification")
                SlateInfoRow(title: "Location", value: spec.managedModelsDirectory.path, monospaced: true)
            }
            SlateDivider()
            SlateRow {
                HStack {
                    modelLoadButton
                    Spacer()
                    Button("Remove") {
                        downloadManager.remove()
                        // Reconcile the cached engine immediately so removing the model
                        // also stops completions and releases its in-memory weights.
                        engineManager.refreshModelInfo()
                    }
                    .buttonStyle(HouseChipButtonStyle(destructive: true))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var modelLoadButton: some View {
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
}

/// The Setup pane: readiness checklist, in-app model acquisition, a built-in
/// practice field for the first completion, and permission status with live
/// refresh. No permission is requested at launch; the user drives setup here.
struct SetupPane: View {
    @ObservedObject var engineManager: EngineManager
    @StateObject private var downloadManager = ModelDownloadManager()
    @StateObject private var permissionMonitor = PermissionMonitor()
    @StateObject private var localModels = LocalModelsMonitor()
    @AppStorage(DaemonRoutedEngine.enabledKey) private var useDaemon = true
    @State private var practiceCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            if useDaemon {
                LocalModelsReadinessChecklist(
                    localModels: localModels,
                    permissionMonitor: permissionMonitor,
                    practiceCompleted: practiceCompleted
                )
                SettingsCard(title: "Local Models", subtitle: "The shared model system Cotype uses for completions") {
                    LocalModelsStatusCard(monitor: localModels)
                }
            } else {
                SetupReadinessChecklist(
                    engineManager: engineManager,
                    downloadManager: downloadManager,
                    permissionMonitor: permissionMonitor,
                    practiceCompleted: practiceCompleted
                )
                SettingsCard(title: "Standalone model", subtitle: "Legacy fallback when Local Models is unavailable") {
                    ModelSetupCard(engineManager: engineManager, downloadManager: downloadManager)
                }
            }
            SettingsCard(title: "Try a completion", subtitle: "A built-in field to test Cotype before using it in your editor") {
                SlateBlock {
                    PracticeField(
                        engineManager: engineManager,
                        daemonReady: localModels.status.isConfiguredModelWarm,
                        onSucceeded: { practiceCompleted = true }
                    )
                }
            }
            SettingsCard(title: "Permissions", subtitle: "Cotype needs these to read and complete text in your editor") {
                permissionRows
                SlateDivider()
                SlateBlock {
                    SlateProse("If Cotype is not listed, press + and choose ~/Applications/Cotype.app, then enable it and relaunch Cotype.", tertiary: true)
                }
            }
        }
        .onAppear {
            downloadManager.onReady = {
                engineManager.refreshModelInfo()
                engineManager.loadIfNeeded()
            }
            downloadManager.refreshInstallationStatus()
            permissionMonitor.start()
            localModels.start()
        }
        .onDisappear { localModels.stop() }
    }

    private var permissionRows: some View {
        VStack(spacing: 0) {
            PermissionStatusRow(
                icon: "accessibility",
                title: "Accessibility",
                caption: "Reads text and pastes into your focused editor",
                granted: permissionMonitor.hasAccessibility,
                opensSettings: { openPrivacy("Privacy_Accessibility") }
            )
            SlateDivider()
            PermissionStatusRow(
                icon: "keyboard",
                title: "Input Monitoring",
                caption: "Monitors the trigger, accept, and cancel keys",
                granted: permissionMonitor.hasInputMonitoring,
                opensSettings: { openPrivacy("Privacy_ListenEvent") }
            )
        }
    }

    private func openPrivacy(_ tab: String) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(tab)")!
        )
    }
}

/// One readiness line: an ink done disc on the left, then the check's title
/// and its detail on the same baseline, as the mockup draws it.
struct ReadinessRow: View {
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            DoneDisc(done: done)
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text(detail)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, House.Spacing.md)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Readiness for the normal Local Models lane. Every check is live: Cotype does
/// not infer readiness from a file path or keep a second model copy.
struct LocalModelsReadinessChecklist: View {
    @ObservedObject var localModels: LocalModelsMonitor
    @ObservedObject var permissionMonitor: PermissionMonitor
    let practiceCompleted: Bool

    private var checks: [(title: String, detail: String, done: Bool)] {
        let status = localModels.status
        return [
            ("Local Models daemon",
             status.isReachable ? "Running" : "Not reachable",
             status.isReachable),
            ("\(status.configuredModelAlias) loaded",
             status.isConfiguredModelWarm ? "Warm and ready" : "Load it from the Local Models menu bar",
             status.isConfiguredModelWarm),
            ("Accessibility permission",
             permissionMonitor.hasAccessibility ? "Granted" : "Open System Settings to grant",
             permissionMonitor.hasAccessibility),
            ("Input Monitoring permission",
             permissionMonitor.hasInputMonitoring ? "Granted" : "Open System Settings to grant",
             permissionMonitor.hasInputMonitoring),
            ("Try a completion",
             practiceCompleted ? "Succeeded" : "Use the practice field below",
             practiceCompleted),
        ]
    }

    var body: some View {
        SettingsCard(title: "Readiness", counter: "\(checks.filter { $0.done }.count) of \(checks.count) complete") {
            ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                if index > 0 { SlateDivider() }
                ReadinessRow(title: check.title, detail: check.detail, done: check.done)
            }
        }
    }
}

/// The first-completion readiness checklist for the legacy standalone lane.
struct SetupReadinessChecklist: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var downloadManager: ModelDownloadManager
    @ObservedObject var permissionMonitor: PermissionMonitor
    let practiceCompleted: Bool

    private var checks: [(title: String, detail: String, done: Bool)] {
        [
            ("Install and verify the model",
             downloadManager.isInstalled ? "Installed" : "Download from the model card below",
             downloadManager.isInstalled),
            ("Model loads locally",
             engineManager.isReady ? "Loaded" : (engineManager.modelPath == nil ? "Install the model first" : "Load it in the model card below"),
             engineManager.isReady),
            ("Accessibility permission",
             permissionMonitor.hasAccessibility ? "Granted" : "Open System Settings to grant",
             permissionMonitor.hasAccessibility),
            ("Input Monitoring permission",
             permissionMonitor.hasInputMonitoring ? "Granted" : "Open System Settings to grant",
             permissionMonitor.hasInputMonitoring),
            ("Try a completion",
             practiceCompleted ? "Succeeded" : "Use the practice field above",
             practiceCompleted),
        ]
    }

    private var completeCount: Int { checks.filter { $0.done }.count }

    var body: some View {
        SettingsCard(title: "Readiness", counter: "\(completeCount) of \(checks.count) complete") {
            ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                if index > 0 { SlateDivider() }
                ReadinessRow(title: check.title, detail: check.detail, done: check.done)
            }
        }
    }
}

/// A safe, built-in text field for the first completion. Runs the local engine
/// directly against the typed text (no Accessibility needed), so a fresh user
/// can confirm the model produces a sensible completion before relying on it in
/// a real editor. The candidate is shown, never inserted anywhere.
struct PracticeField: View {
    @ObservedObject var engineManager: EngineManager
    var daemonReady = false
    let onSucceeded: () -> Void

    @AppStorage(DaemonRoutedEngine.enabledKey) private var useDaemon = true
    @State private var text = ""
    @State private var candidate = ""
    @State private var isRunning = false
    @State private var succeeded = false
    @State private var errorText: String?
    @State private var completionTask: Task<Void, Never>?
    /// The ghost left after a next-word accept, kept for the text it belongs to.
    @State private var remainder: (text: String, ghost: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            // The candidate is rendered inline inside the same editor, after the
            // user's text, as dim gray ghost text — not as a separate card.
            InlinePracticeEditor(text: $text, candidate: candidate, onAcceptKey: accept)
                .frame(minHeight: 72)
                .padding(House.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(House.ColorToken.well)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                )
            HStack {
                SlateProse(statusText, tertiary: true)
                Spacer()
                if succeeded {
                    StatusPill(text: "Completion ready", tint: House.ColorToken.success)
                }
            }
            if let errorText {
                SlateProse(errorText, tertiary: true)
            }
        }
        // Match normal Cotype behavior: pause briefly after typing, then stream
        // an inline completion automatically. Every edit cancels stale work.
        .onChange(of: text) { _, newText in
            scheduleCompletion(for: newText)
        }
        .onDisappear {
            completionTask?.cancel()
        }
    }

    private var engineReady: Bool {
        useDaemon ? daemonReady : engineManager.modelPath != nil
    }

    private var statusText: String {
        if isRunning { return "Completing…" }
        if !engineReady { return "Load the completion model to try it here." }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Start typing to see an automatic completion."
        }
        return succeeded ? "Keep typing to try another completion." : "Pause typing to complete."
    }

    /// Accept with the key and mode chosen in Shortcuts, like the real app.
    private func accept(_ key: AcceptBehavior.Key) -> Bool {
        let behavior = AcceptBehaviorStore.load()
        guard !candidate.isEmpty, key == behavior.key else { return false }
        let segment = behavior.mode == .wholeSuggestion
            ? candidate
            : CompletionInteraction.nextWordSegment(candidate)
        guard !segment.isEmpty else { return false }
        let rest = String(candidate.dropFirst(segment.count))
        let newText = text + segment
        remainder = rest.isEmpty ? nil : (newText, rest)
        text = newText
        return true
    }

    private func scheduleCompletion(for input: String) {
        if let remainder, remainder.text == input {
            // A next-word accept: keep showing the rest of the suggestion.
            completionTask?.cancel()
            candidate = remainder.ghost
            self.remainder = nil
            return
        }
        remainder = nil
        completionTask?.cancel()
        candidate = ""
        succeeded = false
        errorText = nil
        isRunning = false

        guard engineReady,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let engine = engineManager
        completionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
                try Task.checkCancellation()
                isRunning = true
                defer {
                    if text == input { isRunning = false }
                }

                let prompt = try await TemplatePromptBuilder(style: PromptStyle.current()).buildPrompt(
                    context: CompletionContext(prefix: input, appIdentifier: "cotype.practice")
                )
                let sanitizer = OutputSanitizer()
                var buffer = ""
                let inferenceEngine: InferenceEngine
                if useDaemon {
                    guard let daemon = DaemonRoutedEngine.daemonEngine() else {
                        throw PracticeCompletionError.daemonConfiguration
                    }
                    inferenceEngine = daemon
                } else {
                    inferenceEngine = engine
                }
                for try await event in inferenceEngine.stream(prompt: prompt) {
                    try Task.checkCancellation()
                    guard text == input else { throw CancellationError() }
                    if case .token(let token) = event {
                        buffer += token
                        candidate = CaretBoundary.reconcile(
                            prefix: input,
                            candidate: sanitizer.process(buffer, promptTail: input).text,
                            isWord: { SpellCheckWords.shared.isWord($0) },
                            modelSawBoundary: prompt.continuation != nil
                        )
                    }
                }
                let sanitized = sanitizer.process(buffer, promptTail: input)
                guard !sanitized.isNoSuggestion else {
                    candidate = ""
                    throw PracticeCompletionError.empty
                }
                candidate = CaretBoundary.reconcile(
                    prefix: input,
                    candidate: sanitized.text,
                    isWord: { SpellCheckWords.shared.isWord($0) },
                    modelSawBoundary: prompt.continuation != nil
                )
                succeeded = true
                onSucceeded()
            } catch is CancellationError {
                // A newer edit owns the preview now.
            } catch {
                guard text == input else { return }
                errorText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }
}

enum PracticeCompletionError: LocalizedError {
    case empty
    case daemonConfiguration

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The model returned no completion. Try adding more context or reload it from Local Models."
        case .daemonConfiguration:
            return "Local Models is enabled but its completion endpoint is invalid."
        }
    }
}

/// A single-line-capable `NSTextView` editor that shows the practice candidate
/// **inline**, after the typed text, as dim gray ghost text — so no separate
/// Candidate card is needed. The user's text stays editable and the ghost is a
/// non-selectable visual preview only.
struct InlinePracticeEditor: NSViewRepresentable {
    @Binding var text: String
    var candidate: String
    /// Called for the configured accept key while a ghost shows. Returns true
    /// when the key was used to accept, so the editor does not also insert it.
    var onAcceptKey: (AcceptBehavior.Key) -> Bool = { _ in false }

    private static let font = NSFont.monospacedSystemFont(
        ofSize: House.TypeToken.Size.bodySmall, weight: .regular
    )

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = Self.font
        // Let the SwiftUI rounded background show through, so the editor corners
        // are not squared off against the card behind it.
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: House.Spacing.xxs, height: House.Spacing.xxs)
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        let composed = text + candidate
        guard textView.string != composed else { return }

        let realText = NSMutableAttributedString(string: text, attributes: [
            .font: Self.font,
            .foregroundColor: House.NSColorToken.textPrimary,
        ])
        if !candidate.isEmpty {
            realText.append(NSAttributedString(string: candidate, attributes: [
                .font: Self.font,
                // The ghost is the inline ghost-text alpha, exactly as the
                // renderer draws it in a real editor.
                .foregroundColor: House.NSColorToken.textPrimary.withAlphaComponent(GhostTextRenderer.ghostAlpha),
            ]))
        }
        textView.textStorage?.setAttributedString(realText)
        // Rest the insertion point at the end of the real text, before the ghost.
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlinePracticeEditor

        init(_ parent: InlinePracticeEditor) {
            self.parent = parent
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                return parent.onAcceptKey(.tab)
            case #selector(NSResponder.moveRight(_:)):
                return parent.onAcceptKey(.rightArrow)
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let string = textView.string
            let ghost = parent.candidate
            var real = string
            // The ghost is always a trailing suffix; strip it so editing the real
            // text never writes the preview into the stored input.
            if !ghost.isEmpty, string.hasSuffix(ghost) {
                real = String(string.dropLast(ghost.count))
            }
            if parent.text != real {
                parent.text = real
            }
        }
    }
}

/// One permission row with a granted/not-granted badge and an action button.
struct PermissionStatusRow: View {
    var icon: String
    var title: String
    var caption: String
    var granted: Bool
    var opensSettings: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            IconTile(symbol: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Text(caption)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
            Spacer(minLength: House.Spacing.sm)
            if granted {
                StatusPill(text: "Granted", tint: House.ColorToken.success)
            } else {
                Button("Enable", action: opensSettings)
                    .buttonStyle(HouseChipButtonStyle())
            }
        }
        .padding(.horizontal, House.Spacing.md)
        .padding(.vertical, House.Spacing.sm)
        .frame(minHeight: House.Control.xlarge)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var completionController: CompletionController

    @AppStorage("systemPrompt") private var systemPrompt =
        AutocompletePrompt.defaultSystem
    @AppStorage("temperature") private var temperature = 0.0
    @AppStorage("maxTokens") private var maxTokens = 64
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage(CompletionController.autoSuggestKey) private var autoSuggest = true
    @AppStorage(SuggestionLength.defaultsKey) private var suggestionLength = SuggestionLength.default.rawValue
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.dark.rawValue
    @StateObject private var launchModel = LaunchAtLoginModel()
    @EnvironmentObject private var reset: SettingsResetCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            SettingsCard(title: "Completions") {
                SlateRow(title: "Enable completions") {
                    InkSwitch(isOn: Binding(
                        get: { completionController.completionsEnabled },
                        set: { completionController.completionsEnabled = $0 }
                    ))
                }
                SlateDivider()
                SlateRow(title: "Suggestion length") {
                    SlateSegmented(
                        options: SuggestionLength.allCases.map { ($0.rawValue, $0.title) },
                        selection: $suggestionLength
                    )
                    .frame(width: 300)
                }
                SlateDivider()
                SlateRow(
                    title: "Suggest while typing",
                    detail: "Off: suggestions appear only on the trigger shortcut."
                ) {
                    InkSwitch(isOn: $autoSuggest)
                }
            }

            SettingsCard(title: "Startup & Display") {
                SlateRow(
                    title: "Launch at Login",
                    detail: launchModel.statusText.isEmpty ? nil : launchModel.statusText
                ) {
                    InkSwitch(isOn: Binding(
                        get: { launchModel.isEnabled },
                        set: { launchModel.setEnabled($0) }
                    ))
                }
                SlateDivider()
                SlateRow(title: "Show menu bar icon") {
                    InkSwitch(isOn: $showMenuBarIcon)
                }
                SlateDivider()
                SlateRow(title: "Appearance", detail: "Applies to every Cotype window.") {
                    SlateSegmented(
                        options: AppearancePreference.allCases.map { ($0.rawValue, $0.title) },
                        selection: $appearance
                    )
                    .frame(width: 220)
                    .onChange(of: appearance) { _, _ in AppearancePreference.applyCurrent() }
                }
            }

            SettingsCard(title: "Model") {
                ModelStatusRow(engineManager: engineManager)
            }

            SettingsCard(title: "Generation") {
                SlateBlock {
                    Text("System prompt")
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    TextEditor(text: $systemPrompt)
                        .font(House.TypeToken.code)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
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
                SlateRow(title: "Temperature") {
                    HStack(spacing: House.Spacing.sm) {
                        Slider(value: $temperature, in: 0...1, step: 0.05)
                            .tint(House.ColorToken.textPrimary)
                            .frame(width: 180)
                        Text(String(format: "%.1f", temperature))
                            .font(House.TypeToken.code)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                SlateDivider()
                SlateRow(title: "Max tokens") {
                    Stepper("\(maxTokens)", value: $maxTokens, in: 16...1024, step: 16)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
            }

            SettingsCard(title: "Note") {
                SlateBlock {
                    SlateProse("The system prompt applies to the next completion. Temperature and max tokens take effect the next time the model is (re)loaded.", tertiary: true)
                }
            }
        }
        .onAppear {
            reset.register("Reset to defaults") {
                systemPrompt = AutocompletePrompt.defaultSystem
                temperature = 0.0
                maxTokens = 64
                appearance = AppearancePreference.dark.rawValue
                AppearancePreference.applyCurrent()
            }
        }
    }
}

/// Wrapping `SMAppService.mainApp` so the Launch at Login toggle is genuinely
/// functional (register/unregister through the OS) and surfaces real errors
/// instead of pretending.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published var isEnabled = false
    @Published var statusText = ""

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusText = "Cotype will open when you log in."
        case .requiresApproval:
            isEnabled = false
            statusText = "Approval needed — enable Cotype under System Settings → General → Login Items."
        case .notRegistered:
            isEnabled = false
            statusText = ""
        case .notFound:
            isEnabled = false
            statusText = "App registration could not be found."
        @unknown default:
            isEnabled = false
            statusText = ""
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusText = "Could not update Launch at Login: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: - Context

struct ContextPane: View {
    @AppStorage("context.selectedText") private var contextSelectedText = true
    @AppStorage("context.windowTree") private var contextWindowTree = false
    @AppStorage(CompletionController.personalFactsKey) private var personalFacts = ""

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            SettingsCard(title: "About you") {
                SlateBlock {
                    SlateProse("Facts Cotype may use in suggestions: names, emails, company, phrases. One per line. Sent only to the local model.", tertiary: true)
                    TextEditor(text: $personalFacts)
                        .font(House.TypeToken.code)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(House.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                .fill(House.ColorToken.well)
                        )
                }
            }
            SettingsCard(title: "Sources") {
                SlateRow(title: "Focused editor text") {
                    Text("Required")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                SlateDivider()
                SlateRow(
                    title: "Visible active-window text",
                    detail: "Reads other text in the same window (for example the chat above your reply). Read through Accessibility, not OCR. Stays on this Mac."
                ) {
                    InkSwitch(isOn: $contextWindowTree)
                }
                SlateDivider()
                SlateRow(title: "Include selected text in custom prompt templates") {
                    InkSwitch(isOn: $contextSelectedText)
                }
                SlateDivider()
                UnavailableToggle("Clipboard", caption: "Not yet supported")
                SlateDivider()
                UnavailableToggle("Screenshot", caption: "Not yet supported")
            }
            SettingsCard(title: "Permissions") {
                PermissionStatusRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    caption: "Needed to read the focused editor and active window",
                    granted: AXIsProcessTrusted(),
                    opensSettings: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                )
                SlateDivider()
                PermissionStatusRow(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    caption: "Needed to monitor the trigger, accept, and cancel keys",
                    granted: CGPreflightListenEventAccess(),
                    opensSettings: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
                )
            }
        }
    }
}

/// A toggle that is visually present but disabled and marked unavailable, so it
/// is never mistaken for a working feature.
struct UnavailableToggle: View {
    var title: String
    var caption: String

    init(_ title: String, caption: String) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        SlateRow(title: title, detail: caption) {
            HStack(spacing: House.Spacing.sm) {
                Text("Unavailable")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                InertToggle()
            }
        }
    }
}

// MARK: - Personalization

struct PersonalizationPane: View {
    let store: PersonalizationStore
    @ObservedObject var engineManager: EngineManager

    // Content logging is OFF by default. Content-free, bounded usage counters
    // are still recorded as documented in Privacy & Data.
    @AppStorage("learnFromFeedback") private var learnFromFeedback = false
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            SettingsCard(title: "Learning") {
                SlateRow(title: "Learn from accepted and rejected completions") {
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
                            detail: sample.completion.isEmpty ? nil : String(sample.completion.prefix(120)),
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

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @State private var shortcut = TriggerShortcutStore.load()
    @State private var recorder: ShortcutRecorderModel?
    @State private var acceptAllShortcut = AcceptAllShortcutStore.load()
    @State private var acceptAllRecorder: ShortcutRecorderModel?
    @State private var acceptBehavior = AcceptBehaviorStore.load()
    @EnvironmentObject private var reset: SettingsResetCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            SettingsCard(title: "Accept") {
                SlateRow(
                    title: "Accept key",
                    detail: "Press it while gray text shows. Otherwise the key reaches your app as normal. ⌘Tab is the macOS app switcher and cannot be used."
                ) {
                    SlateSegmented(
                        options: AcceptBehavior.Key.allCases.map { ($0.rawValue, $0.title) },
                        selection: Binding(
                            get: { acceptBehavior.key.rawValue },
                            set: { raw in
                                acceptBehavior.key = AcceptBehavior.Key(rawValue: raw) ?? .tab
                                AcceptBehaviorStore.save(acceptBehavior)
                            }
                        )
                    )
                    .frame(width: 220)
                }

                SlateDivider()

                SlateRow(
                    title: "One press accepts",
                    detail: "Next word: press again to keep going. Whole suggestion: one press inserts it all."
                ) {
                    SlateSegmented(
                        options: AcceptBehavior.Mode.allCases.map { ($0.rawValue, $0.title) },
                        selection: Binding(
                            get: { acceptBehavior.mode.rawValue },
                            set: { raw in
                                acceptBehavior.mode = AcceptBehavior.Mode(rawValue: raw) ?? .nextWord
                                AcceptBehaviorStore.save(acceptBehavior)
                            }
                        )
                    )
                    .frame(width: 260)
                }

                SlateDivider()

                SlateRow(
                    title: "Accept all",
                    detail: "A modifier plus the accept key (default ⌥ + accept key) always inserts the whole suggestion. Command is never used."
                ) {
                    HStack(spacing: House.Spacing.sm) {
                        KeyCaps(chord: acceptAllShortcut.displayString)
                        Button(acceptAllRecorder?.isRecording == true ? "Recording… (Esc to cancel)" : "Record") {
                            if acceptAllRecorder?.isRecording == true {
                                acceptAllRecorder?.stop()
                                acceptAllRecorder = nil
                            } else {
                                let model = ShortcutRecorderModel { captured in
                                    let chord = AcceptAllShortcut(modifiers: captured.modifiers)
                                    acceptAllShortcut = chord
                                    AcceptAllShortcutStore.save(chord)
                                }
                                model.onFinished = { acceptAllRecorder = nil }
                                acceptAllRecorder = model
                                model.start()
                            }
                        }
                        .buttonStyle(HouseChipButtonStyle())
                    }
                }

                SlateDivider()
                SlateBlock {
                    SlateProse("If the chord conflicts with a system or app shortcut, Cotype defers to the host app (Command is never hijacked).", tertiary: true)
                }

                SlateDivider()

                ShortcutRow(title: "Cancel", key: "esc", caption: "Dismiss the offered completion and briefly pause auto-trigger.")
            }

            SettingsCard(title: "Ask for a suggestion now (optional)") {
                SlateRow(
                    title: "Suggest now",
                    detail: "Suggestions already appear while you type. This chord forces one on demand. It needs a modifier (⌃, ⌥, or ⇧) plus a key. To change the accept key, use Accept above."
                ) {
                    HStack(spacing: House.Spacing.sm) {
                        KeyCaps(chord: shortcut.displayString)
                        Button(recorder?.isRecording == true ? "Recording… (Esc to cancel)" : "Record") {
                            if recorder?.isRecording == true {
                                recorder?.stop()
                                recorder = nil
                            } else {
                                let model = ShortcutRecorderModel { captured in
                                    shortcut = captured
                                    TriggerShortcutStore.save(captured)
                                }
                                model.onFinished = { recorder = nil }
                                recorder = model
                                model.start()
                            }
                        }
                        .buttonStyle(HouseChipButtonStyle())
                    }
                }
                SlateDivider()
                SlateBlock {
                    SlateProse("If you pick a chord that conflicts with a system or app shortcut, Cotype defers to the host app (Command is never hijacked).", tertiary: true)
                }
            }

            SettingsCard(title: "Note") {
                SlateBlock {
                    SlateProse("The trigger is consumed only when it actually runs a completion; otherwise it is passed to your editor. Switching apps or moving focus cancels the offered completion so it is never pasted into the wrong app.", tertiary: true)
                }
            }
        }
        .onAppear {
            reset.register("Reset to defaults") {
                shortcut = .default
                TriggerShortcutStore.save(.default)
                acceptAllShortcut = .default
                AcceptAllShortcutStore.save(.default)
                acceptBehavior = .default
                AcceptBehaviorStore.save(.default)
            }
        }
    }
}

/// Records a modifier chord by capturing the next non-modifier keypress while a
/// local key monitor runs (the settings window is key, so the global monitor
/// passes keys through). The chord is saved to `TriggerShortcutStore`.
@MainActor
final class ShortcutRecorderModel: NSObject, ObservableObject {
    @Published var isRecording = false

    private let onRecorded: (TriggerShortcut) -> Void
    /// Called whenever recording ends (captured or cancelled), so the view can
    /// clear its own recording state. The view cannot observe `isRecording`
    /// through an optional `@State` reference, which left "Recording…" stuck.
    var onFinished: (() -> Void)?
    private var monitor: Any?

    init(onRecorded: @escaping (TriggerShortcut) -> Void) {
        self.onRecorded = onRecorded
    }

    func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let type = event.type
            let consume = MainActor.assumeIsolated { self.shouldConsume(type: type, keyCode: keyCode, flags: flags) }
            return consume ? nil : event
        }
    }

    func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let finished = onFinished
        onFinished = nil
        finished?()
    }

    /// Returns true if the event should be consumed (a chord was captured or
    /// recording was cancelled); false passes the event through untouched.
    private func shouldConsume(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if type == .flagsChanged { return false }
        // Escape cancels recording.
        if keyCode == 53 {
            stop()
            return true
        }
        // Record any key that is not a bare modifier.
        guard let baseKey = KeyboardLayoutResolver.unmodifiedBaseKey(forKeyCode: keyCode) else {
            return false
        }
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.shift)   { modifiers.insert(.shift) }

        // Command chords are owned by the host app or macOS. Leave the event
        // untouched and keep recording rather than persisting an unusable chord.
        guard !modifiers.isEmpty, !modifiers.contains(.command) else { return false }
        onRecorded(TriggerShortcut(modifiers: modifiers, key: baseKey))
        stop()
        return true
    }
}

struct ShortcutRow: View {
    var title: String
    var key: String
    var caption: String?

    var body: some View {
        SlateRow(title: title, detail: caption) {
            KeyCaps(chord: key)
        }
    }
}

// MARK: - Statistics

struct StatisticsPane: View {
    let store: PersonalizationStore
    @State private var refresh = 0

    var body: some View {
        let summary = store.usageSummary()
        let perApp = perAppBreakdown()

        VStack(alignment: .leading, spacing: House.Spacing.md) {
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
            SettingsCard(title: "Per app") {
                if perApp.isEmpty {
                    SlateBlock {
                        SlateProse("No samples yet.", tertiary: true)
                    }
                } else {
                    ForEach(Array(perApp.enumerated()), id: \.offset) { index, entry in
                        if index > 0 { SlateDivider() }
                        SlateRow(title: appDisplayName(for: entry.app), minHeight: 38) {
                            Text("\(entry.accepted) accepted · \(entry.dismissed) dismissed · \(entry.canceled) canceled")
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

    private func perAppBreakdown() -> [(app: String, accepted: Int, dismissed: Int, canceled: Int)] {
        let all = store.samples()
        let grouped = Dictionary(grouping: all, by: { $0.appIdentifier })
        return grouped
            .map { app, samples in
                (app: app,
                 accepted: samples.filter { $0.outcome == .accepted }.count,
                 dismissed: samples.filter { $0.outcome == .dismissed }.count,
                 canceled: samples.filter { $0.outcome == .canceled }.count)
            }
            .sorted { $0.accepted + $0.dismissed + $0.canceled > $1.accepted + $1.dismissed + $1.canceled }
    }
}

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
        VStack(alignment: .leading, spacing: House.Spacing.md) {
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

// MARK: - Outcome presentation helpers

func outcomeIcon(for outcome: PersonalizationOutcome) -> String {
    switch outcome {
    case .accepted: return "checkmark.circle.fill"
    case .dismissed: return "xmark.circle.fill"
    case .shown: return "eye.fill"
    case .canceled: return "minus.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
}

func outcomeTint(for outcome: PersonalizationOutcome) -> Color {
    switch outcome {
    case .accepted: return House.ColorToken.success
    case .dismissed: return House.ColorToken.warning
    case .shown: return House.ColorToken.textTertiary
    case .canceled: return House.ColorToken.textTertiary
    case .failed: return House.ColorToken.warning
    }
}

func outcomeLabel(for outcome: PersonalizationOutcome) -> String {
    switch outcome {
    case .accepted: return "Accepted"
    case .dismissed: return "Dismissed"
    case .shown: return "Offered"
    case .canceled: return "Canceled"
    case .failed: return "Failed"
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var updater: SparkleUpdateController
    @State private var notarization: NotarizationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
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

// MARK: - Contact Support

struct ContactSupportPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
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
