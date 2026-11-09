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

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private let notifications: NotificationCenter
    private let readPermissions: () -> (accessibility: Bool, inputMonitoring: Bool, postEvent: Bool)
    var isMonitoring: Bool { timer != nil }

    init(
        notifications: NotificationCenter = .default,
        readPermissions: @escaping () -> (accessibility: Bool, inputMonitoring: Bool, postEvent: Bool) = {
            (AXIsProcessTrusted(), CGPreflightListenEventAccess(), CGPreflightPostEventAccess())
        }
    ) {
        self.notifications = notifications
        self.readPermissions = readPermissions
        refresh()
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        activationObserver = notifications.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { notifications.removeObserver(activationObserver) }
        activationObserver = nil
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { notifications.removeObserver(activationObserver) }
    }

    func refresh() {
        let snapshot = readPermissions()
        hasAccessibility = snapshot.accessibility
        hasInputMonitoring = snapshot.inputMonitoring
        hasPostEventAccess = snapshot.postEvent
    }
}

/// The Setup pane: readiness checklist, Local Models status, a built-in
/// practice field for the first completion, and permission status with live
/// refresh. No permission is requested at launch; the user drives setup here.
struct SetupPane: View {
    @StateObject private var permissionMonitor = PermissionMonitor()
    @StateObject private var localModels = LocalModelsMonitor()
    @State private var practiceCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
            LocalModelsReadinessChecklist(
                localModels: localModels,
                permissionMonitor: permissionMonitor,
                practiceCompleted: practiceCompleted
            )
            SettingsCard(title: "Local Models", subtitle: "The shared model system Cotype uses for completions") {
                LocalModelsStatusCard(monitor: localModels)
            }
            SettingsCard(title: "Try a completion", subtitle: "A built-in field to test Cotype before using it in your editor") {
                SlateBlock {
                    PracticeField(
                        daemonReady: localModels.status.readiness.isReady,
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
            permissionMonitor.start()
            localModels.start()
        }
        .onDisappear {
            permissionMonitor.stop()
            localModels.stop()
        }
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
             status.readiness.summary(modelAlias: status.configuredModelAlias),
             status.readiness.isReady),
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

/// A safe, built-in text field for the first completion. Runs Local Models
/// directly against the typed text (no Accessibility needed), so a fresh user
/// can confirm the model produces a sensible completion before relying on it in
/// a real editor. The candidate is shown, never inserted anywhere.
struct PracticeField: View {
    var daemonReady = false
    let onSucceeded: () -> Void

    @StateObject private var model = PracticeCompletionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            // The candidate is rendered inline inside the same editor, after the
            // user's text, as dim gray ghost text — not as a separate card.
            InlinePracticeEditor(text: $model.text, candidate: model.candidate, onAcceptKey: model.accept)
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
                if model.succeeded {
                    StatusPill(text: "Completion ready", tint: House.ColorToken.success)
                }
            }
            if let errorText = model.errorText {
                SlateProse(errorText, tertiary: true)
            }
        }
        // Match normal Cotype behavior: pause briefly after typing, then stream
        // an inline completion automatically. Every edit cancels stale work.
        .onChange(of: model.text) { _, newText in
            model.scheduleCompletion(for: newText, daemonReady: daemonReady, onSucceeded: onSucceeded)
        }
        .onDisappear {
            model.cancel()
        }
    }

    private var statusText: String {
        if model.isRunning { return "Completing…" }
        if !daemonReady { return "Load the completion model to try it here." }
        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Start typing to see an automatic completion."
        }
        return model.succeeded ? "Keep typing to try another completion." : "Pause typing to complete."
    }

}

/// Owns practice generation, including request identity across identical edits.
/// The view and tests use the same interface; injected engines never read AX.
@MainActor
final class PracticeCompletionModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var candidate = ""
    @Published private(set) var isRunning = false
    @Published private(set) var succeeded = false
    @Published private(set) var errorText: String?
    private(set) var completionTask: Task<Void, Never>?
    private var activeRequest: UUID?
    private var remainder: (text: String, ghost: String)?
    private let debounce: Duration
    private let engine: () -> InferenceEngine

    init(debounce: Duration = .milliseconds(450), engine: @escaping () -> InferenceEngine = {
        DaemonRoutedEngine.daemonEngine()
    }) {
        self.debounce = debounce
        self.engine = engine
    }

    func cancel() {
        activeRequest = nil
        completionTask?.cancel()
        completionTask = nil
        isRunning = false
    }

    /// Accept with the key and mode chosen in Shortcuts, like the real app.
    func accept(_ key: AcceptBehavior.Key) -> Bool {
        let behavior = AcceptBehaviorStore.load()
        guard !candidate.isEmpty, key == behavior.key else { return false }
        let segment = behavior.mode == .wholeSuggestion
            ? candidate
            : CompletionInteraction.nextWordSegment(candidate)
        guard !segment.isEmpty else { return false }
        let rest = String(candidate.dropFirst(segment.count))
        let newText = text + segment
        cancel()
        remainder = rest.isEmpty ? nil : (newText, rest)
        candidate = rest
        text = newText
        return true
    }

    func scheduleCompletion(for input: String, daemonReady: Bool, onSucceeded: @escaping () -> Void) {
        if let remainder, remainder.text == input {
            // A next-word accept: keep showing the rest of the suggestion.
            cancel()
            candidate = remainder.ghost
            self.remainder = nil
            return
        }
        remainder = nil
        cancel()
        candidate = ""
        succeeded = false
        errorText = nil
        isRunning = false

        guard daemonReady,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let request = UUID()
        activeRequest = request
        completionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                guard activeRequest == request else { return }
                isRunning = true
                defer {
                    if activeRequest == request { isRunning = false; completionTask = nil }
                }

                let prompt = try await TemplatePromptBuilder(style: PromptStyle.current()).buildPrompt(
                    context: CompletionContext(prefix: input, appIdentifier: "cotype.practice")
                )
                try Task.checkCancellation()
                guard activeRequest == request else { return }
                let sanitizer = OutputSanitizer()
                var buffer = ""
                for try await event in engine().stream(prompt: prompt) {
                    try Task.checkCancellation()
                    guard activeRequest == request else { throw CancellationError() }
                    if case .end = event { break }
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
                try Task.checkCancellation()
                guard activeRequest == request else { return }
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
                guard activeRequest == request, !Task.isCancelled else { return }
                errorText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }
}

enum PracticeCompletionError: LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The model returned no completion. Try adding more context or reload it from Local Models."
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

