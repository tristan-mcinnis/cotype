import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

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
                HStack(spacing: House.Spacing.xs) {
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
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
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
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
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
            HStack(spacing: House.Spacing.xs) {
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

