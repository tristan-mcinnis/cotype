import Foundation
import AppKit
import Combine
import CotypeCore

/// Drives the completion loop for the menu-bar app.
///
/// A completion is always previewed before insertion. The controller rejects
/// stale callbacks, cancels pending suggestions when focus changes, refuses
/// sensitive or unreadable contexts, and records content only with consent.
///
/// Focused-field safety: every completion captures an exact `FocusTarget`
/// (app + window + element) at trigger time. The ghost is only rendered, and a
/// candidate only accepted/inserted, while that focus target is still valid —
/// failing closed on any same-app window/element switch or caret move.
@MainActor
public final class CompletionController: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case generating
        case awaitingAccept
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var currentCandidate: String = ""
    @Published public private(set) var lastError: String?
    @Published public private(set) var storageWarning: String?
    /// Whether the ghost overlay is actually on screen, as the production
    /// renderer reports it after AppKit applied a draw or hide. A candidate can
    /// be ready while its ghost is hidden (no caret geometry, the field is too
    /// narrow, or the render guard failed closed).
    @Published public private(set) var isGhostVisible = false
    @Published public var completionsEnabled: Bool {
        didSet { userDefaults.set(completionsEnabled, forKey: "enableCompletions") }
    }

    public let engineManager: EngineManager
    public let personalization: PersonalizationStore
    public let overrides: AppOverridesStore
    private let notShown: NotShownStore?
    private var notShownRecorded: Set<NotShownReason> = []

    private let inserter: CompletionInserter
    /// One overlay renderer for the controller's lifetime. Reusing it prevents
    /// completed generations from leaving separate NSWindow instances onscreen.
    private let overlayRenderer: CompletionRenderer
    private let pipelineEngineOverride: InferenceEngine?
    /// Resolves the Local Models daemon engine for the current defaults, or nil
    /// when daemon mode is off / the endpoint is unusable. Injected so tests can
    /// substitute a deterministic daemon engine; production uses
    /// `DaemonRoutedEngine.daemonEngine(defaults:)`.
    private let daemonEngineProvider: (UserDefaults) -> InferenceEngine?
    /// Overrides the context provider. Injected so tests (which route through the
    /// daemon seam) do not touch the live focused element; production is nil and
    /// uses the fail-closed Accessibility provider.
    private let contextProviderOverride: ContextProvider?
    private let frontmostAppProvider: () -> String?
    private let focusIdentityProvider: FocusIdentityProvider
    private let userDefaults: UserDefaults
    private var collectingRenderer: CollectingRenderer?
    private var pipelineTask: Task<Void, Never>?

    private var activeAppIdentifier = "unknown"
    private var activeFocusTarget: FocusTarget?
    private var activePrefix = ""
    private var flow = CompletionFlow()
    private var frontmostChangeObserver: NSObjectProtocol?

    // MARK: - Typing interaction loop

    /// The pure interaction loop state machine. It decides *when* to generate,
    /// cancel, accept, type-through, and dismiss; this controller runs the
    /// resulting effects (timers, pipeline, insertion).
    private var interaction = CompletionInteraction()

    /// Pause window before a generation auto-triggers after typing stops.
    /// TabType defaults to 90 ms and cotabby/KeyType to 15-55 ms; the local
    /// daemon answers in about 200 ms, so 120 ms keeps the ghost close behind
    /// the caret without generating on every keystroke of a burst.
    public var debounceInterval: TimeInterval = 0.12

    /// UserDefaults key for automatic suggestions while typing. The app
    /// registers it as `true`; the manual trigger chord always works too.
    public static let autoSuggestKey = "autoSuggest"

    /// UserDefaults key for the user's "About you" facts (names, emails,
    /// company). Appended to the system prompt, where it stays stable across
    /// keystrokes so the server's prompt cache still applies.
    public static let personalFactsKey = "personalFacts"
    /// How long Escape suppresses auto-trigger after a dismissal.
    public var cooldownInterval: TimeInterval = 0.6

    private var debounceTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    /// The last ghost shown in the overlay, so `refreshFromInteraction` only
    /// re-renders when the ghost actually changes (type-through shrinks it).
    private var lastRenderedGhost: String?
    /// The generation whose overlay has actually become visible and therefore
    /// has already contributed one `.shown` metric.
    private var shownMetricGenerationID: Int?
    /// Serializes accepted-segment insertions so rapid Tab stepping never races;
    /// each commit awaits the previous one.
    private var commitTask: Task<Void, Never>?
    /// The generation that produced the candidate currently being accepted. It is
    /// both the *render epoch* (which ghost may be drawn) and the *commit-chain
    /// epoch* (which chain a failure belongs to). It is intentionally NOT bumped
    /// by `flow.accept()` on a stepped accept, so the remainder ghost stays valid.
    private var activeRenderGenerationID = 0
    /// Epochs (generation ids) whose commit chain already failed: further commits
    /// for them are refused, and a later generation is unaffected because it has a
    /// distinct epoch.
    private var failedCommitEpochs: Set<Int> = []

    public init(
        engineManager: EngineManager,
        personalization: PersonalizationStore = PersonalizationStore(),
        overrides: AppOverridesStore = AppOverridesStore(),
        notShown: NotShownStore? = nil,
        inserter: CompletionInserter = CompletionInsertionRouter(),
        renderer: CompletionRenderer = GhostTextRenderer(),
        pipelineEngineOverride: InferenceEngine? = nil,
        daemonEngineProvider: @escaping (UserDefaults) -> InferenceEngine? = {
            DaemonRoutedEngine.daemonEngine(defaults: $0)
        },
        contextProviderOverride: ContextProvider? = nil,
        frontmostAppProvider: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        focusIdentityProvider: FocusIdentityProvider? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.engineManager = engineManager
        self.notShown = notShown
        self.personalization = personalization
        self.overrides = overrides
        self.inserter = inserter
        self.overlayRenderer = renderer
        self.pipelineEngineOverride = pipelineEngineOverride
        self.daemonEngineProvider = daemonEngineProvider
        self.contextProviderOverride = contextProviderOverride
        self.frontmostAppProvider = frontmostAppProvider
        self.focusIdentityProvider = focusIdentityProvider ?? AXFocusIdentityProvider()
        self.userDefaults = userDefaults
        completionsEnabled = userDefaults.object(forKey: "enableCompletions") as? Bool ?? true

        personalization.onWriteFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.storageWarning = "Feedback could not be saved: \(message)"
            }
        }
        observeFrontmostChanges()
    }

    public var isBusy: Bool { phase == .generating }
    public var hasPendingCompletion: Bool { phase == .awaitingAccept }
    public var candidateAvailable: Bool { !currentCandidate.isEmpty }
    /// Whether the accept key may be taken from the focused app: a candidate is
    /// ready AND the user can see it. A hidden candidate must never swallow Tab
    /// and insert text the user did not see; Tab then reaches the app as usual.
    public var isAcceptKeyReady: Bool { hasPendingCompletion && isGhostVisible }

    private func observeFrontmostChanges() {
        frontmostChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                AXWake.noteActivated(app)
                TerminalCaret.reset()
                self?.noteFrontmostAppChanged(app?.bundleIdentifier)
            }
        }
    }

    /// Cancels a pending candidate when the insertion target changes.
    public func noteFrontmostAppChanged(_ bundleID: String?) {
        guard phase != .idle else { return }
        guard FocusGuardPolicy.shouldCancelPending(
            activeAppIdentifier: activeAppIdentifier,
            currentFrontmost: bundleID
        ) else { return }
        CotypeLog.loop.info("dismiss: frontmost app changed from \(self.activeAppIdentifier, privacy: .public)")
        cancel(recordingRejection: true)
    }

    /// Manual force-trigger. Routes through the interaction machine so the loop
    /// stays consistent: it supersedes any in-flight generation, works during
    /// cooldown, and returns true only when a generation actually started (so
    /// the trigger key is consumed only then).
    @discardableResult
    public func trigger() -> Bool {
        applyInteraction(.manualTrigger)
    }

    /// Feed ordinary typing into the interaction loop. The loop is manual-first,
    /// so typing only *invalidates* a live candidate/generation; it never arms
    /// the debounce timer or starts a generation of its own. Gating — sensitive
    /// context and disabled apps — is enforced when a generation actually begins
    /// (`performGenerate`), never here, so typing is never swallowed.
    public func noteTyped(_ text: String) {
        guard !text.isEmpty else { return }
        syncAutoSuggestSetting()
        if AppCompatibility.isTerminal(frontmostAppProvider() ?? "") {
            TerminalCaret.noteTyped(text)
        }
        let wasAwaiting = interaction.state == .awaitingAccept
        applyInteraction(.typed(text))
        if wasAwaiting, interaction.state != .awaitingAccept {
            CotypeLog.loop.info("dismiss: typed text did not match the ghost in \(self.activeAppIdentifier, privacy: .public)")
        }
        if wasAwaiting, interaction.state == .awaitingAccept {
            // Type-through (auto lane only) advanced the caret by exactly the
            // typed text. Advance the captured target by arithmetic, as an
            // accepted insertion does, instead of re-reading AX: the key monitor
            // only waits one main-run-loop turn, and Chromium/Electron apply
            // the key to their AX tree later than that, so a live read here
            // could capture the pre-key caret and fail every later check. The
            // render guard and accept still compare against a live read, so a
            // host that did something else fails closed.
            activeFocusTarget = Self.targetAfterInsertion(activeFocusTarget, text: text)
        }
    }

    /// Observe a keyboard-originated non-printable document mutation (backspace,
    /// forward delete, return, paste/cut/undo/redo, or unmodified Tab with no
    /// candidate). It invalidates any stale ghost/generation without arming the
    /// debounce; the key itself is never consumed.
    public func noteEdited() {
        syncAutoSuggestSetting()
        TerminalCaret.reset()
        if phase == .awaitingAccept {
            CotypeLog.loop.info("dismiss: editing key in \(self.activeAppIdentifier, privacy: .public)")
        }
        applyInteraction(.edited)
    }

    /// Read the automatic-suggestion preference at the moment it matters, so a
    /// Settings toggle applies to the next keystroke and defaults registered
    /// after this controller was built are still honoured.
    private func syncAutoSuggestSetting() {
        interaction.autoSuggestEnabled = userDefaults.bool(forKey: Self.autoSuggestKey)
    }

    /// Observe a pointer/navigation-originated context change (a mouse-down moved
    /// the caret or focus, or the window/element changed). Like `noteEdited` it
    /// invalidates any stale ghost/generation, and by construction it can never
    /// arm the debounce — not even in the future automatic lane.
    public func noteContextMoved() {
        TerminalCaret.reset()
        if phase == .awaitingAccept {
            CotypeLog.loop.info("dismiss: caret or focus moved in \(self.activeAppIdentifier, privacy: .public)")
        }
        applyInteraction(.contextMoved)
    }

    /// Tab: accept the next word of the current suggestion, keeping the rest as
    /// a ghost so further Tab presses step through it.
    public func acceptNextWord() {
        applyInteraction(.acceptNextWord)
    }

    /// Dismiss the current candidate and briefly pause auto-trigger (Escape).
    public func dismiss() {
        cancel(recordingRejection: true)
    }

    /// The actual generation core. Performs the gating checks (disabled app,
    /// sensitive context via the pipeline, no model) and starts a pipeline run.
    /// Returns false when the trigger should pass through (gated/disabled).
    @discardableResult
    private func performGenerate(source: CompletionInteraction.Source) -> Bool {
        guard completionsEnabled else {
            noteNotShown(.completionsDisabled, appIdentifier: frontmostAppProvider() ?? "unknown")
            lastError = "Completions are disabled."
            CotypeLog.loop.debug("skip: completions disabled")
            return false
        }

        let appIdentifier = frontmostAppProvider() ?? "unknown"
        let override = overrides.override(for: appIdentifier)
        // Terminals are off unless the user enabled the app explicitly, like
        // every reference app: no caret bounds, and Tab belongs to the shell.
        let explicitOverride = overrides.rawOverride(for: appIdentifier)?.enabled
        guard AppCompatibility.isEnabled(bundleID: appIdentifier, override: explicitOverride ?? override.enabled) else {
            if source == .manual {
                lastError = "Completions are off for \(appIdentifier). Turn it on in Apps settings."
            }
            CotypeLog.loop.debug("skip: disabled for \(appIdentifier, privacy: .public)")
            noteNotShown(.appDisabled, appIdentifier: appIdentifier)
            return false
        }
        // Daemon mode is a first-class production model source: with the Local
        // Models daemon toggle on, generation proceeds even with no in-process
        // model path (Cotype is a thin client of the daemon's registry). When
        // daemon mode is off, the no-model block applies exactly as before.
        let daemonEngine = daemonEngineProvider(userDefaults)
        guard pipelineEngineOverride != nil || daemonEngine != nil || engineManager.modelPath != nil else {
            lastError = "No model installed. Open Cotype Setup to install the local model."
            CotypeLog.loop.error("skip: no model")
            noteNotShown(.noModel, appIdentifier: appIdentifier)
            return false
        }

        // Fail closed: an exact focused-field identity is required before context
        // capture, rendering, acceptance, or insertion.
        guard let focusTarget = focusIdentityProvider.currentFocusTarget() else {
            lastError = "Cotype could not identify the focused editor. Check Accessibility permission."
            CotypeLog.loop.info("skip: no focused editor in \(appIdentifier, privacy: .public)")
            noteNotShown(.noFocusedEditor, appIdentifier: appIdentifier)
            return false
        }

        // Supersede any straggling in-flight generation before starting fresh.
        // The machine already emitted .cancelGeneration for the normal cases;
        // this guards the direct/defensive path.
        if flow.isActive {
            abortInFlight()
        }

        notShownRecorded = []
        // A fresh generation starts a fresh commit-chain / render epoch.
        let myID = flow.beginGeneration()
        activeRenderGenerationID = myID
        failedCommitEpochs = []
        phase = .generating

        let length = SuggestionLength.current(userDefaults)
        let defaultPrompt = userDefaults.string(forKey: "systemPrompt")
            ?? AutocompletePrompt.defaultSystem
        let facts = userDefaults.string(forKey: Self.personalFactsKey) ?? ""
        var promptBuilder = TemplatePromptBuilder(
            systemTemplate: AutocompletePrompt.withPersonalFacts(
                length.applied(to: override.systemPrompt ?? defaultPrompt),
                facts: facts
            ),
            // A per-app system prompt only means something to the instruction
            // prompt, so an app with one keeps that style.
            style: override.systemPrompt == nil ? PromptStyle.current(userDefaults) : .instruction,
            personalFacts: facts
        )
        if contentLoggingEnabled {
            let store = personalization
            promptBuilder.personalizationSummary = {
                PersonalizationFewShot.summary(
                    for: store.samples(forApp: appIdentifier),
                    filterApp: appIdentifier
                )
            }
        }

        // Hide the previous generation, then reuse the controller's single
        // overlay window for the fresh stream.
        collectingRenderer?.clear()

        let renderer = CollectingRenderer(inner: overlayRenderer)
        // Coalesce the engine's per-token callbacks into at most one pending
        // main-actor update per run-loop turn (the newest token wins). This keeps
        // the full AX editor traversal out of the streaming path: focus is
        // revalidated at the render and accept boundaries instead.
        let coalescer = StreamedCandidateCoalescer(deliver: { [weak self] pending in
            self?.trackCandidate(pending.text, generationID: pending.generationID)
        })
        renderer.onCandidate = { candidate in
            coalescer.submit(candidate, generationID: myID)
        }
        // Only ever draw after this generation is still the active render epoch
        // and the focus target still matches; otherwise the deferred drain fails
        // closed (see `canRenderGhost`).
        renderer.renderGuard = { [weak self] in self?.canRenderGhost() ?? false }
        renderer.onNotShown = { [weak self] reason in
            guard let self, self.activeRenderGenerationID == myID else { return }
            self.noteNotShown(reason, appIdentifier: self.activeAppIdentifier)
        }
        renderer.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            // One overlay window serves every generation, so this mirrors the
            // window whichever generation drew or hid it.
            if self.isGhostVisible != visible { self.isGhostVisible = visible }
            guard visible,
                  self.activeRenderGenerationID == myID,
                  self.shownMetricGenerationID != myID
            else { return }
            self.shownMetricGenerationID = myID
            self.personalization.recordShown(appIdentifier: self.activeAppIdentifier)
        }
        collectingRenderer = renderer

        let includeSelectedText = userDefaults.object(forKey: "context.selectedText") as? Bool ?? true
        // Manual v1: the active-window AX tree (a second, bounded tree walk) is
        // off unless the user opts in. The key is injectable via UserDefaults;
        // there is deliberately no UI in this slice.
        let includeWindowContext = userDefaults.object(forKey: "context.windowTree") as? Bool ?? false
        let detector = SensitiveContextDetector(userExclusions: personalization.userExcludedApps)
        // Production resolves the engine: the daemon seam when Local Models daemon
        // mode is on, otherwise the in-process EngineManager. The injected pipeline
        // override stays a pure test seam and takes precedence over both.
        let engine: InferenceEngine = pipelineEngineOverride
            ?? daemonEngine
            ?? engineManager
        // An injected inference engine (pipeline override or daemon seam) is a
        // deterministic test seam and must not touch the live focused element.
        // Production always uses the fail-closed Accessibility provider.
        let contextProvider: ContextProvider = contextProviderOverride
            ?? (pipelineEngineOverride == nil
                ? AXTextContextProvider(
                    includeSelectedText: includeSelectedText,
                    includeWindowContext: includeWindowContext,
                    sensitiveDetector: detector
                )
                : StaticContextProvider())
        let pipeline = CompletionPipeline(
            contextProvider: contextProvider,
            promptBuilder: promptBuilder,
            engine: engine,
            renderer: renderer,
            inserter: inserter
        )
        pipeline.wordChecker = { SpellCheckWords.shared.isWord($0) }
        pipeline.maxWords = length.maxWords

        let cancellable = pipeline.events.sink { [weak self] event in
            if event.phase == .context, let context = event.payload as? CompletionContext {
                DispatchQueue.main.async {
                    guard let self, self.flow.isCurrent(myID), self.flow.isGenerating else { return }
                    self.activePrefix = context.prefix
                }
            }
        }

        let request = CompletionRequest(appIdentifier: appIdentifier, prefix: "", suffix: "")
        lastError = nil
        activeAppIdentifier = appIdentifier
        activeFocusTarget = focusTarget
        activePrefix = ""

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await pipeline.complete(request)
                await MainActor.run {
                    guard self.flow.isCurrent(myID) else { return }
                    self.completeSuccessfully(result, abstained: pipeline.lastRunAbstained)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.flow.isCurrent(myID) else { return }
                    self.releaseAfterCancel()
                }
            } catch let sensitive as SensitiveContextError {
                await MainActor.run {
                    guard self.flow.isCurrent(myID) else { return }
                    self.releaseAfterPrivacyGate(sensitive)
                }
            } catch {
                await MainActor.run {
                    guard self.flow.isCurrent(myID) else { return }
                    self.releaseAfterFailure(error)
                }
            }
            await MainActor.run { cancellable.cancel() }
        }
        return true
    }

    private func completeSuccessfully(_ result: String, abstained: Bool) {
        CotypeLog.loop.debug("generated \(result.count, privacy: .public) chars for \(self.activeAppIdentifier, privacy: .public)")
        // Validate the exact focus target once at the candidate boundary — the
        // last moment before a ghost could be drawn or accepted — rather than on
        // every streamed token. The render guard already fails closed per draw;
        // this catches a same-app window/element change during a slow generation
        // so the loop returns to idle instead of parking in `awaitingAccept`.
        guard isFocusTargetValid() else {
            CotypeLog.loop.info("drop: focus target changed during generation in \(self.activeAppIdentifier, privacy: .public)")
            noteNotShown(.focusChangedDuringGeneration, appIdentifier: activeAppIdentifier)
            cancel(recordingRejection: true)
            return
        }
        if result.isEmpty {
            CotypeLog.loop.info("none: no usable suggestion for \(self.activeAppIdentifier, privacy: .public)")
            noteNotShown(abstained ? .abstainedInsideWord : .emptyCompletion, appIdentifier: activeAppIdentifier)
            flow.finishWithoutCandidate()
            applyInteraction(.noSuggestion)
            clearRequestIdentity()
        } else {
            flow.candidateReady()
            applyInteraction(.generated(result))
        }
    }

    private func releaseAfterPrivacyGate(_ gate: SensitiveContextError) {
        CotypeLog.loop.info("gate: \(String(describing: gate), privacy: .public) in \(self.activeAppIdentifier, privacy: .public)")
        switch gate {
        case .gated(let category): noteNotShown(NotShownReason(gate: category), appIdentifier: activeAppIdentifier)
        case .unreadable: noteNotShown(.unreadableContext, appIdentifier: activeAppIdentifier)
        }
        collectingRenderer?.clear()
        applyInteraction(.noSuggestion)
        clearRequestIdentity()
        lastError = Self.message(for: gate)
    }

    private func releaseAfterFailure(_ error: Error) {
        CotypeLog.loop.error("fail: \((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)), privacy: .public) in \(self.activeAppIdentifier, privacy: .public)")
        let appIdentifier = activeAppIdentifier
        noteNotShown(.engineFailure, appIdentifier: appIdentifier)
        collectingRenderer?.clear()
        applyInteraction(.noSuggestion)
        clearRequestIdentity()
        lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        personalization.recordFailed(appIdentifier: appIdentifier)
    }

    private func releaseAfterCancel() {
        let appIdentifier = activeAppIdentifier
        noteNotShown(.cancelledWhileGenerating, appIdentifier: appIdentifier)
        clearActiveState()
        flow.cancel()
        personalization.recordCanceled(appIdentifier: appIdentifier)
    }

    /// Whether the captured focus target (the exact editor current at trigger
    /// time) still matches what is focused right now. Fails closed on any change
    /// or on any nil.
    private func isFocusTargetValid() -> Bool {
        FocusIdentityPolicy.isValid(
            captured: activeFocusTarget,
            current: focusIdentityProvider.currentFocusTarget()
        )
    }

    /// Apply a coalesced streamed candidate to the interaction loop.
    ///
    /// Deliberately performs NO AX read: a full focused-editor traversal per
    /// streamed token was the dominant cost in the streaming path. Focus is
    /// revalidated where it matters — once at the candidate boundary
    /// (`completeSuccessfully`), the render guard (`canRenderGhost`) before
    /// anything is drawn, and the accept/commit boundaries before anything is
    /// inserted — so wrong-target insertion protection is unchanged.
    private func trackCandidate(_ candidate: String, generationID: Int) {
        guard flow.isCurrent(generationID), flow.isGenerating else { return }
        applyInteraction(.streamed(candidate))
    }

    /// Render-time guard for the deferred ghost draw. State-aware and
    /// generation-specific: only draws while the machine is actively showing a
    /// ghost, the render epoch is still active, and the exact focus target still
    /// matches. It deliberately does NOT use `flow.isCurrent` because a stepped
    /// accept bumps `flow.generation` while the stepped remainder ghost stays
    /// valid; a superseded/escaped/edited drain is rejected instead by the
    /// state + ghost-emptiness checks.
    private func canRenderGhost() -> Bool {
        guard activeRenderGenerationID != 0 else { return false }
        guard interaction.isGenerating || interaction.isAwaitingAccept else { return false }
        guard !interaction.ghost.isEmpty else { return false }
        let valid = isFocusTargetValid()
        if !valid {
            CotypeLog.loop.info("hide: focus target no longer matches in \(self.activeAppIdentifier, privacy: .public)")
            noteNotShown(.focusMismatchAtRender, appIdentifier: activeAppIdentifier)
        }
        return valid
    }

    /// Dismiss the remainder of a commit chain, but only if it is still the
    /// active candidate. A stale chain's failure must never clear a newer
    /// generation's ghost.
    private func dismissCommitRemainder(epoch: Int) {
        guard epoch == activeRenderGenerationID else { return }
        _ = applyInteraction(.dismissed)
    }

    /// Accept the whole suggestion (full-suggestion chord / menu). Routes through
    /// the machine so the loop stays consistent.
    public func accept() {
        guard phase == .awaitingAccept, candidateAvailable, activeAppIdentifier != "unknown" else {
            return
        }
        guard isFocusTargetValid() else {
            CotypeLog.loop.info("drop: focus target changed before accept in \(self.activeAppIdentifier, privacy: .public)")
            cancel(recordingRejection: true)
            return
        }
        applyInteraction(.acceptAll)
    }

    /// Cancel/dismiss. Routes through the machine (`dismissed`) so the loop
    /// enters a brief cooldown, then records the rejection.
    public func cancel(recordingRejection: Bool = true) {
        let wasShown = phase == .awaitingAccept
        if wasShown || phase == .generating {
            CotypeLog.loop.debug("dismiss: cancelled in \(self.activeAppIdentifier, privacy: .public)")
        }
        if phase == .generating {
            noteNotShown(.cancelledWhileGenerating, appIdentifier: activeAppIdentifier)
        }
        let candidate = currentCandidate
        let appIdentifier = activeAppIdentifier
        let prefix = activePrefix

        applyInteraction(.dismissed)

        if wasShown {
            if contentLoggingEnabled, recordingRejection, !candidate.isEmpty {
                personalization.recordDismissed(
                    prefix: prefix,
                    completion: candidate,
                    appIdentifier: appIdentifier
                )
            } else {
                personalization.recordMetric(.dismissed, appIdentifier: appIdentifier)
            }
        } else if appIdentifier != "unknown" {
            personalization.recordCanceled(appIdentifier: appIdentifier)
        }
    }

    // MARK: - Interaction driver

    /// Feed an event into the interaction machine and execute its effects.
    /// Returns true when a generation actually started (so the trigger key is
    /// consumed only then).
    @discardableResult
    private func applyInteraction(_ event: CompletionInteraction.Event) -> Bool {
        let effects = interaction.handle(event)
        var generationStarted = false
        for effect in effects {
            switch effect {
            case .none:
                break
            case .startDebounce:
                scheduleDebounce()
            case .startCooldown:
                scheduleCooldown()
            case .cancelGeneration:
                abortInFlight()
            case .beginGeneration(let source):
                if performGenerate(source: source) {
                    generationStarted = true
                } else {
                    // Gated/disabled (sensitive context, disabled app, no model):
                    // revert the machine so it does not sit in `.generating` with
                    // nothing running.
                    _ = interaction.handle(.noSuggestion)
                }
            case .commit(let segment):
                commitSegment(segment)
            }
        }
        refreshFromInteraction()
        return generationStarted
    }

    /// Sync the published phase + candidate from the machine, and keep the ghost
    /// overlay in sync (it shrinks as the user types through a match and clears
    /// on dismiss/accept).
    private func refreshFromInteraction() {
        switch interaction.state {
        case .idle, .debouncing, .cooldown:
            phase = .idle
        case .generating:
            phase = .generating
        case .awaitingAccept:
            phase = .awaitingAccept
        }
        currentCandidate = interaction.ghost

        if interaction.ghost != lastRenderedGhost {
            lastRenderedGhost = interaction.ghost
            if interaction.ghost.isEmpty {
                collectingRenderer?.clear()
            } else {
                collectingRenderer?.setGhost(interaction.ghost)
            }
        }
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
            guard !Task.isCancelled, self.interaction.state == .debouncing else { return }
            _ = self.applyInteraction(.debounceElapsed)
        }
    }

    private func scheduleCooldown() {
        cooldownTask?.cancel()
        let interval = cooldownInterval
        cooldownTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
            guard !Task.isCancelled, self.interaction.state == .cooldown else { return }
            _ = self.applyInteraction(.cooldownElapsed)
        }
    }

    /// Counts one not-shown reason per request. A request that already drew a
    /// ghost is not counted again for later redraw failures.
    private func noteNotShown(_ reason: NotShownReason, appIdentifier: String) {
        guard let notShown else { return }
        let alreadyDrawn = shownMetricGenerationID == activeRenderGenerationID
        if alreadyDrawn, [.noCaretGeometry, .ghostDoesNotFit, .focusMismatchAtRender].contains(reason) { return }
        guard notShownRecorded.insert(reason).inserted else { return }
        notShown.record(reason, appIdentifier: appIdentifier)
    }

    /// Cancel the in-flight pipeline without recording a rejection. Used when
    /// typing supersedes a generation or a mismatch regenerates.
    ///
    /// `activeRenderGenerationID` is deliberately NOT reset here: the render
    /// guard already rejects a stale ghost via the state/ghost-emptiness checks,
    /// while an in-flight commit chain from the previous epoch still needs to
    /// recognize its own epoch so it completes/fails cleanly without poisoning a
    /// later generation.
    private func abortInFlight() {
        if flow.isGenerating {
            noteNotShown(.cancelledWhileGenerating, appIdentifier: activeAppIdentifier)
        }
        flow.cancel()
        pipelineTask?.cancel()
        collectingRenderer?.clear()
        lastRenderedGhost = nil
    }

    /// Accept a segment of the candidate into the editor. For a full accept the
    /// loop ends (state idle); for a stepped next-word accept the remaining ghost
    /// stays and the tracked prefix advances.
    ///
    /// Commits are **serialized** (each awaits the previous one) and scoped to a
    /// commit-chain *epoch* (the generation that produced the candidate). If any
    /// commit in the chain fails, only that epoch is latched and its remainder is
    /// dismissed; a later generation has a distinct epoch and is never poisoned.
    /// Each segment revalidates the exact focus target just before insert (fail
    /// closed on a moved caret), and a successful stepped insert refreshes the
    /// captured target so the next queued segment validates against the new caret.
    private func commitSegment(_ text: String) {
        guard !text.isEmpty else { return }
        // Already-failed chain: refuse (a fresh epoch is needed to accept again).
        if failedCommitEpochs.contains(activeRenderGenerationID) { return }
        let epoch = activeRenderGenerationID
        let appIdentifier = activeAppIdentifier
        let prefix = activePrefix
        flow.accept()
        pipelineTask?.cancel()

        let keepAccepting = interaction.state == .awaitingAccept
        let chainEnding = !keepAccepting
        if keepAccepting {
            activePrefix = prefix + text
        }
        // Deliberately do NOT clearActiveState here: the in-flight commit chain
        // still needs `activeFocusTarget` (and the request identity) to revalidate
        // each queued segment. The last chain task clears it after the final insert
        // (a worked example of the orchestrator's "full accept may capture its
        // target before clear state").

        let previous = commitTask
        commitTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Skip if this chain was superseded by a fresh generation or already
            // failed — never insert a segment the machine no longer stands behind.
            guard self.activeRenderGenerationID == epoch,
                  !self.failedCommitEpochs.contains(epoch) else { return }

            // Revalidate the CURRENT exact target against the expected one (the
            // target the previous insert left, or the captured one for the first
            // segment). The field-aware inserter re-verifies the passed target
            // too, so a moved caret fails closed here or at insert.
            guard self.isFocusTargetValid() else {
                CotypeLog.loop.info("drop: focus target changed before insert in \(appIdentifier, privacy: .public)")
                await MainActor.run {
                    self.failedCommitEpochs.insert(epoch)
                    self.dismissCommitRemainder(epoch: epoch)
                    if chainEnding { self.clearRequestIdentity() }
                    self.personalization.recordFailed(appIdentifier: appIdentifier)
                    self.lastError = "The focus changed before the completion was inserted."
                }
                return
            }
            let expectedTarget = self.activeFocusTarget

            do {
                try await self.inserter.insert(text, appIdentifier: appIdentifier, focusTarget: expectedTarget)
                await MainActor.run {
                    // A stepped insert advances the caret; refresh the active
                    // target deterministically from the approved element/range and
                    // inserted text. Re-reading "whatever is focused now" creates
                    // a race where a newly focused field can become authorized for
                    // the next segment.
                    if keepAccepting {
                        self.activeFocusTarget = Self.targetAfterInsertion(expectedTarget, text: text)
                    }
                    if AppCompatibility.isTerminal(appIdentifier) {
                        // The typed-in completion is now on screen after the
                        // user's keys; the next caret match must include it.
                        TerminalCaret.noteTyped(text)
                    }
                    if chainEnding { self.clearRequestIdentity() }
                    if self.contentLoggingEnabled {
                        self.personalization.recordAccepted(
                            prefix: prefix,
                            completion: text,
                            appIdentifier: appIdentifier
                        )
                    } else {
                        self.personalization.recordMetric(.accepted, appIdentifier: appIdentifier)
                    }
                }
            } catch {
                CotypeLog.loop.error("fail: insert failed in \(appIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.failedCommitEpochs.insert(epoch)
                    self.dismissCommitRemainder(epoch: epoch)
                    if chainEnding { self.clearRequestIdentity() }
                    self.personalization.recordFailed(appIdentifier: appIdentifier)
                    self.lastError = "Could not insert completion: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(interval * 1_000_000_000)
    }

    private static func targetAfterInsertion(_ target: FocusTarget?, text: String) -> FocusTarget? {
        guard let target else { return nil }
        guard case .range? = target.selection else { return target }
        guard let nextSelection = target.expectedSelectionAfterInserting(text) else { return nil }
        return FocusTarget(
            appIdentifier: target.appIdentifier,
            windowIdentity: target.windowIdentity,
            elementIdentity: target.elementIdentity,
            selection: .range(nextSelection)
        )
    }

    private func clearActiveState() {
        collectingRenderer?.clear()
        currentCandidate = ""
        phase = .idle
        clearRequestIdentity()
        lastRenderedGhost = nil
    }

    private func clearRequestIdentity() {
        activeAppIdentifier = "unknown"
        activeFocusTarget = nil
        activePrefix = ""
        // Do NOT reset activeRenderGenerationID here: the in-flight commit chain
        // of the currently-accepted candidate still needs to recognize its own
        // epoch so the final (often sole) commit is not dropped.
    }

    private var contentLoggingEnabled: Bool {
        userDefaults.object(forKey: "learnFromFeedback") as? Bool ?? false
    }

    private static func message(for gate: SensitiveContextError) -> String {
        switch gate {
        case .unreadable:
            return "Cotype could not safely read the focused text. Check Accessibility permission."
        case .gated(.secureTextField), .gated(.protectedContent):
            return "Completion is disabled in secure or protected text fields."
        case .gated(.sensitiveApp):
            return "Completion is disabled for this sensitive app."
        case .gated(.userExcludedApp):
            return "Completion is disabled because you excluded this app."
        }
    }
}

/// Collects the streaming candidate and forwards it to the controller for
/// validation (`onCandidate`), but **does not render**. Rendering is driven by
/// the controller via `setGhost` only after it has confirmed this generation is
/// still current and the focus target still matches — a stale streamed token can
/// never be drawn before validation.
final class CollectingRenderer: CompletionRenderer {
    var onCandidate: ((String) -> Void)?

    /// The underlying renderer. Injected so tests can spy on renders; production
    /// uses the ghost-text overlay.
    private let inner: CompletionRenderer

    init(inner: CompletionRenderer = GhostTextRenderer()) {
        self.inner = inner
    }

    func present(_ candidate: String, for request: CompletionRequest) {
        // Only collect/callback. The controller may render after validation.
        onCandidate?(candidate)
    }

    func clear() {
        inner.clear()
    }

    /// Update the ghost overlay without re-triggering the candidate callback.
    /// Used when the interaction loop shrinks/clears the ghost via type-through
    /// or accept — after the controller has validated generation + focus. The
    /// `CompletionRequest` is vestigial for positioning.
    func setGhost(_ candidate: String) {
        inner.present(candidate, for: CompletionRequest())
    }

    /// Forward the render-time guard to the underlying ghost renderer.
    var renderGuard: (@MainActor () -> Bool)? {
        get { (inner as? GhostTextRenderer)?.renderGuard }
        set { (inner as? GhostTextRenderer)?.renderGuard = newValue }
    }

    var onNotShown: (@MainActor (NotShownReason) -> Void)? {
        get { (inner as? GhostTextRenderer)?.onNotShown }
        set { (inner as? GhostTextRenderer)?.onNotShown = newValue }
    }

    /// Forward real post-AppKit visibility changes from the production overlay.
    var onVisibilityChanged: (@MainActor (Bool) -> Void)? {
        get { (inner as? GhostTextRenderer)?.onVisibilityChanged }
        set { (inner as? GhostTextRenderer)?.onVisibilityChanged = newValue }
    }

    /// Whether the underlying ghost overlay is showing. Exposed for tests.
    var isShowing: Bool { (inner as? GhostTextRenderer)?.isShowing ?? false }
}

/// Coalesces a burst of streamed candidate callbacks into at most one pending
/// delivery per run-loop turn.
///
/// The engine streams tokens from a background task while the controller renders
/// on the main actor. Every `submit` stores the newest candidate and schedules a
/// single drain; interleaved tokens in the same turn collapse to the newest one,
/// so the main actor performs at most one update per run-loop turn and the AX
/// focus read stays out of the per-token path.
///
/// `submit` is called from the pipeline's executor and `drain` from the scheduled
/// lane, so all mutable state is guarded by `lock` — which is the whole reason
/// for the `@unchecked Sendable` conformance.
final class StreamedCandidateCoalescer: @unchecked Sendable {
    struct Pending: Equatable {
        var text: String
        var generationID: Int
    }

    /// Runs the scheduled drain. Injected so tests can drain deterministically.
    typealias Scheduler = (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var pending: Pending?
    private var scheduled = false
    private let schedule: Scheduler
    private let deliver: (Pending) -> Void

    init(
        schedule: @escaping Scheduler = { DispatchQueue.main.async(execute: $0) },
        deliver: @escaping (Pending) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// Store the newest candidate and schedule one drain if none is pending.
    func submit(_ text: String, generationID: Int) {
        lock.lock()
        pending = Pending(text: text, generationID: generationID)
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        schedule { [weak self] in self?.drain() }
    }

    /// Deliver the newest pending candidate, if any.
    func drain() {
        lock.lock()
        scheduled = false
        let item = pending
        pending = nil
        lock.unlock()

        guard let item else { return }
        deliver(item)
    }
}
