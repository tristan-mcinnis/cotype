import Foundation
import AppKit
import CoreGraphics
import Carbon
import CotypeMacOS

// MARK: - Main run-loop hop

/// Schedules `work` on the next turn of the main run loop and returns
/// immediately.
///
/// Both event-tap threads and the Carbon hot-key handler must return before any
/// Accessibility or model work runs, so none of them may call the controller
/// directly. `CFRunLoopPerformBlock` is explicitly safe to call from another
/// thread, and it keeps the hop on the main run loop the UI already drains —
/// no `DispatchQueue` bridge and no new fire-and-forget `Task`.
@inline(__always)
private func hopToMain(_ work: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString) {
        MainActor.assumeIsolated { work() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

// MARK: - Cross-thread commands

/// Which keyboard tap produced a command.
enum KeyboardTapMode: Sendable {
    /// `.listenOnly`, always on: reports typing/edits for the automatic lane and
    /// can never consume an event.
    case typingObserver
    /// `.defaultTap`, installed only while a completion is live: consumes the
    /// accept/cancel keys and forwards everything else untouched.
    case interaction
}

/// A command a tap produces on its own thread and delivers on the main actor.
enum TapCommand: Sendable {
    case perform(TapAction)
    case observe(EditObservation)
    /// The system disabled that tap (timeout or secure input).
    case recoverDisabledTap(KeyboardTapMode)
}

// MARK: - Keyboard tap engine

/// Owns one keyboard-only `CGEventTap` and its dedicated run-loop thread.
///
/// Deliberately **not** actor-isolated: the tap callback runs on the tap thread
/// and must read the routing snapshot without hopping to the main actor. Every
/// piece of shared mutable state is guarded by `lock`, which is the entire
/// reason for the `@unchecked Sendable` conformance.
///
/// The callback contract is O(1): check the synthetic tag first, read one
/// lock-protected snapshot, make a pure decision, and hop to the main run loop
/// at most once. No Accessibility call, no `UserDefaults` read, no
/// keyboard-layout table copy, and no controller call happens on the tap thread.
final class KeyboardTapEngine: @unchecked Sendable {

    private struct Installed {
        let tap: CFMachPort
        let loop: CFRunLoop
    }

    private let mode: KeyboardTapMode
    private let lock = NSLock()
    private var snapshot: TapRouteSnapshot
    private var installed: Installed?
    private var wantsRunning = false
    private var threadAlive = false
    /// Set when a start arrives while a thread is still tearing down, so the
    /// departing thread relaunches exactly once instead of spinning.
    private var restartRequested = false
    private let deliver: @Sendable (TapCommand) -> Void

    init(
        mode: KeyboardTapMode,
        snapshot: TapRouteSnapshot,
        deliver: @escaping @Sendable (TapCommand) -> Void
    ) {
        self.mode = mode
        self.snapshot = snapshot
        self.deliver = deliver
    }

    /// Publish a freshly resolved snapshot. The tap thread only ever reads it.
    func update(snapshot newSnapshot: TapRouteSnapshot) {
        lock.lock()
        snapshot = newSnapshot
        lock.unlock()
    }

    /// Ask for the tap to be installed on its dedicated run-loop thread.
    ///
    /// If a teardown is still in flight, the departing thread restarts itself
    /// instead, so a fast off→on cycle can never leave the tap silently absent.
    func start() {
        lock.lock()
        wantsRunning = true
        if threadAlive { restartRequested = true }
        lock.unlock()
        spawnThreadIfNeeded()
    }

    /// Deterministic teardown: disable the tap immediately (so no further event
    /// is routed) and ask the run loop to stop. The stop is queued onto the run
    /// loop itself, so it also lands correctly if the thread has not reached
    /// `CFRunLoopRun()` yet. The tap thread then removes its own source and
    /// invalidates the port.
    func stop() {
        lock.lock()
        wantsRunning = false
        let current = installed
        lock.unlock()
        guard let current else { return }
        CGEvent.tapEnable(tap: current.tap, enable: false)
        CFRunLoopPerformBlock(current.loop, CFRunLoopMode.commonModes.rawValue as CFString) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(current.loop)
    }

    /// Turn a system-disabled tap back on without rebuilding it.
    func reEnable() {
        lock.lock()
        let current = installed
        lock.unlock()
        guard let current else { return }
        CGEvent.tapEnable(tap: current.tap, enable: true)
    }

    private func spawnThreadIfNeeded() {
        lock.lock()
        guard wantsRunning, !threadAlive else {
            lock.unlock()
            return
        }
        threadAlive = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = mode == .typingObserver ? "Cotype.TypingObserverTap" : "Cotype.InteractionTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func runTapLoop() {
        guard let loop = CFRunLoopGetCurrent() else {
            finishThread()
            return
        }
        guard let tap = CGEvent.tapCreate(
            // Session level, like TabType, KeyType, and cotabby: it sees
            // hardware keys and text posted by other apps (dictation, scripted
            // input). Cotype's own posted events are tagged and ignored below.
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // The observer is listen-only: it is structurally incapable of
            // blocking or consuming an event. The active tap may consume the
            // accept/cancel keys.
            options: mode == .typingObserver ? .listenOnly : .defaultTap,
            eventsOfInterest: TapLifecycle.eventMask,
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Cotype: could not create the \(mode == .typingObserver ? "typing observer" : "interaction") key event tap (needs Input Monitoring).")
            finishThread()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            finishThread()
            return
        }

        lock.lock()
        // A stop can race in before the thread installed; honour it.
        installed = Installed(tap: tap, loop: loop)
        let shouldStop = !wantsRunning
        lock.unlock()

        if !shouldStop {
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }

        // Teardown on the tap thread itself: removing the source here avoids
        // mutating the run loop from another thread.
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        finishThread()
    }

    private func finishThread() {
        lock.lock()
        installed = nil
        threadAlive = false
        // Relaunch only for a start that arrived while this thread was still
        // departing. A failed install never relaunches, so a missing Input
        // Monitoring grant cannot spin here.
        let restart = restartRequested && wantsRunning
        restartRequested = false
        lock.unlock()
        if restart { spawnThreadIfNeeded() }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turned the tap off without asking. Recover on the main
            // actor, which knows whether it is still wanted.
            deliver(.recoverDisabledTap(mode))
            return Unmanaged.passUnretained(event)
        case .keyDown:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        // Synthetic tagging first: an event Cotype posted itself fails open
        // before any routing, so it is never consumed and never observed.
        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        guard !SyntheticEventTag.isTagged(sourceUserData: sourceUserData) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeyModifiers(from: event.flags)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch mode {
        case .typingObserver:
            // Listen-only: always forwards. It only reports the observation, and
            // it never reports a key another path owns (see the pure model).
            let current = readSnapshot()
            let text = Self.typedText(from: event)
            if let observation = current.typingObservation(
                keyCode: keyCode,
                modifiers: modifiers,
                text: text,
                isRepeat: isRepeat
            ) {
                deliver(.observe(observation))
            }
            return Unmanaged.passUnretained(event)

        case .interaction:
            // Narrow: consume accept/cancel, forward everything else so the
            // listen-only observer can report whatever survives.
            let current = readSnapshot()
            switch current.route(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) {
            case .consume(let action):
                deliver(.perform(action))
                return nil
            case .pass:
                return Unmanaged.passUnretained(event)
            }
        }
    }

    private func readSnapshot() -> TapRouteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// The characters a key-down event carries, empty for non-typing events.
    private static func typedText(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}

/// `@convention(c)` function pointer for `CGEvent.tapCreate`. Retrieves the
/// engine from `userInfo` rather than capturing any context.
private let keyboardTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<KeyboardTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

/// `@convention(c)` function pointer for the registered trigger hot key. It only
/// schedules the trigger on the main run loop and returns; no Accessibility or
/// model work runs inside the Carbon callback.
private let cotypeHotKeyHandler: EventHandlerUPP = { _, _, userInfo in
    guard let userInfo else { return noErr }
    let monitor = Unmanaged<GlobalKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    hopToMain { monitor.triggerFromHotKey() }
    return noErr
}

// MARK: - GlobalKeyMonitor

/// Monitors typing, the accept/cancel keys, and the manual trigger chord.
///
/// Three paths, each with one job:
///
/// - **Typing observer** (always on). A `.listenOnly` `CGEventTap` on its own
///   run-loop thread reports ordinary typing and document edits so suggestions
///   can follow typing. It is structurally incapable of blocking or consuming
///   an event.
/// - **Active tap** (only while a generation or candidate is live). A narrow
///   `.defaultTap` accepts the next word with unmodified Tab, accepts the whole
///   candidate with the accept-all chord, cancels with Escape, and forwards
///   everything else — including Shift+Tab and every Command chord.
/// - **Mouse** (passive). No tap ever intercepts a mouse event. A passive
///   `NSEvent` global monitor reports clicks so a stale candidate is
///   invalidated; it can never start a generation.
///
/// The registered Carbon hot key keeps the manual trigger available as a
/// fallback in every state. Because a registered hot key is owned by the system,
/// the chosen trigger chord is always swallowed while Cotype is enabled and its
/// own window is not key; Cotype releases the chord entirely while completions
/// are disabled or its settings window is key.
///
/// The split is deterministic rather than order-dependent: both taps read the
/// same pure snapshot, and the observer never reports a key that the registered
/// hot key or the active tap owns, no matter which tap the system runs first.
@MainActor
public final class GlobalKeyMonitor {

    // MARK: Callbacks

    /// Returns true when the trigger actually started a completion.
    public var onTrigger: (@MainActor () -> Bool)?
    /// Unmodified Tab with a candidate ready: accept the next word.
    public var onAcceptWord: (@MainActor () -> Void)?
    /// The full-suggestion chord (default Option+Tab) with a candidate ready:
    /// accept the whole suggestion.
    public var onAcceptAll: (@MainActor () -> Void)?
    public var onCancel: (@MainActor () -> Void)?
    /// Ordinary typed text (a single printable character, no Command/Control/
    /// Option). Feeds the typing interaction loop and is **never consumed**.
    public var onTyped: (@MainActor (String) -> Void)?
    /// A keyboard-originated non-printable document mutation
    /// (backspace/delete, return, paste/cut/undo/redo, unmodified Tab with no
    /// candidate). Invalidates any stale ghost/generation; never consumed.
    public var onEdited: (@MainActor () -> Void)?
    /// A pointer-originated context change (a click moved the caret or changed
    /// focus). Cancels/invalidates only; it can never start a generation.
    public var onContextMoved: (@MainActor () -> Void)?

    // MARK: Configuration

    /// The configured trigger chord. Loading/saving through `TriggerShortcutStore`
    /// keeps the monitor and the General pane in sync.
    public var triggerShortcut: TriggerShortcut {
        didSet {
            guard oldValue != triggerShortcut else { return }
            resolveTriggerKeyCodes()
            refreshSnapshots()
            applyLifecycle()
        }
    }

    /// The configured full-suggestion accept chord (default Option+Tab).
    public var acceptAllShortcut: AcceptAllShortcut {
        didSet {
            guard oldValue != acceptAllShortcut else { return }
            refreshSnapshots()
        }
    }

    /// True while a completion is in flight or awaiting acceptance.
    public var acceptBehavior: AcceptBehavior = AcceptBehaviorStore.load() {
        didSet {
            guard oldValue != acceptBehavior else { return }
            refreshSnapshots()
        }
    }

    public var isCompletionActive = false {
        didSet {
            guard oldValue != isCompletionActive else { return }
            refreshSnapshots()
        }
    }

    /// True only once a candidate is fully generated, awaiting acceptance, and
    /// its ghost is on screen (`CompletionController.isAcceptKeyReady`).
    public var isAcceptReady = false {
        didSet {
            guard oldValue != isAcceptReady else { return }
            refreshSnapshots()
        }
    }

    /// True while Cotype's own settings window is the key window.
    public var isSelfActive = false {
        didSet {
            guard oldValue != isSelfActive else { return }
            refreshSnapshots()
            // Release the trigger hot key while Cotype's own window is key, so
            // the Shortcuts recorder can capture the current chord.
            applyLifecycle()
        }
    }

    /// Mirrors the completions-enabled preference. While completions are
    /// disabled Cotype watches nothing and reserves no chord.
    public var completionsEnabled = true {
        didSet {
            guard oldValue != completionsEnabled else { return }
            refreshSnapshots()
        }
    }

    // MARK: State

    private var typingEngine: KeyboardTapEngine?
    private var interactionEngine: KeyboardTapEngine?
    private var isTypingObserverInstalled = false
    private var isInteractionTapInstalled = false
    private var triggerKeyCodes: Set<UInt16> = []
    private var triggerHandled = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var clickMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var layoutObserver: NSObjectProtocol?

    private static let hotKeySignature: OSType = 0x4354_5950 // 'CTYP'
    private static let hotKeyID: UInt32 = 1

    public init(
        triggerShortcut: TriggerShortcut? = nil,
        acceptAllShortcut: AcceptAllShortcut? = nil
    ) {
        self.triggerShortcut = triggerShortcut ?? TriggerShortcutStore.load()
        self.acceptAllShortcut = acceptAllShortcut ?? AcceptAllShortcutStore.load()
    }

    // MARK: Lifecycle

    public func start() {
        resolveTriggerKeyCodes()
        refreshSnapshots()
        observeShortcutDefaults()
        observeKeyboardLayoutChanges()
        // The listen-only typing observer starts here; the active tap is still
        // only installed once a generation or candidate is live.
        applyLifecycle()
    }

    public func stop() {
        isTypingObserverInstalled = false
        isInteractionTapInstalled = false
        typingEngine?.stop()
        interactionEngine?.stop()
        unregisterTriggerHotKey()
        removeClickMonitor()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
        defaultsObserver = nil
        layoutObserver = nil
    }

    /// Explicitly set the trigger chord (persisting it), used by the settings UI.
    public func setTriggerShortcut(_ shortcut: TriggerShortcut) {
        TriggerShortcutStore.save(shortcut)
        triggerShortcut = shortcut
    }

    /// Explicitly set the full-suggestion accept chord (persisting it), used by
    /// the settings UI.
    public func setAcceptAllShortcut(_ shortcut: AcceptAllShortcut) {
        AcceptAllShortcutStore.save(shortcut)
        acceptAllShortcut = shortcut
    }

    /// Install or uninstall every global input path from the current state. The
    /// app delegate calls this from its phase hook.
    public func applyLifecycle() {
        let plan = GlobalInputLifecycle.plan(
            isSelfActive: isSelfActive,
            isCompletionActive: isCompletionActive,
            completionsEnabled: completionsEnabled
        )

        // Install the observer first so the active tap is created after it (taps
        // are head-inserted). The pure snapshot already prevents a consumed key
        // from also being observed, so this is ordering hygiene, not a correctness
        // dependency.
        switch TapLifecycle.instruction(
            isInstalled: isTypingObserverInstalled,
            shouldBeInstalled: plan.installsTypingObserver
        ) {
        case .install:
            isTypingObserverInstalled = true
            typingTapEngine().start()
        case .remove:
            isTypingObserverInstalled = false
            typingEngine?.stop()
        case .keep, .reEnable:
            break
        }

        switch TapLifecycle.instruction(
            isInstalled: isInteractionTapInstalled,
            shouldBeInstalled: plan.installsInteractionTap
        ) {
        case .install:
            isInteractionTapInstalled = true
            interactionTapEngine().start()
        case .remove:
            isInteractionTapInstalled = false
            interactionEngine?.stop()
        case .keep, .reEnable:
            break
        }

        if plan.registersTriggerHotKey {
            registerTriggerHotKey()
        } else {
            unregisterTriggerHotKey()
        }

        if plan.monitorsClicks {
            installClickMonitor()
        } else {
            removeClickMonitor()
        }
    }

    // MARK: Snapshot plumbing

    private func currentInteractionSnapshot() -> TapRouteSnapshot {
        TapRouteSnapshot(
            isSelfActive: isSelfActive,
            isCompletionActive: isCompletionActive,
            isAcceptReady: isAcceptReady,
            trigger: triggerShortcut,
            acceptAll: acceptAllShortcut,
            triggerKeyCodes: triggerKeyCodes,
            triggerHandled: triggerHandled,
            triggerOwnedByHotKey: hotKeyRef != nil,
            accept: acceptBehavior
        )
    }

    private func refreshSnapshots() {
        let snapshot = currentInteractionSnapshot()
        typingEngine?.update(snapshot: snapshot)
        interactionEngine?.update(snapshot: snapshot)
    }

    /// Resolve the trigger character to key codes in the *current* layout. This
    /// is the only place a layout table is read, and it never runs on a tap
    /// thread.
    private func resolveTriggerKeyCodes() {
        triggerKeyCodes = Set(KeyboardLayoutResolver.keyCodes(forCharacter: triggerShortcut.key))
    }

    private func typingTapEngine() -> KeyboardTapEngine {
        if let typingEngine { return typingEngine }
        // Held for the lifetime of the monitor: the tap thread may still be
        // finishing teardown after `stop()`, so the engine must outlive it.
        let engine = KeyboardTapEngine(
            mode: .typingObserver,
            snapshot: currentInteractionSnapshot()
        ) { [weak self] command in
            hopToMain { self?.handle(command) }
        }
        typingEngine = engine
        return engine
    }

    private func interactionTapEngine() -> KeyboardTapEngine {
        if let interactionEngine { return interactionEngine }
        let engine = KeyboardTapEngine(
            mode: .interaction,
            snapshot: currentInteractionSnapshot()
        ) { [weak self] command in
            hopToMain { self?.handle(command) }
        }
        interactionEngine = engine
        return engine
    }

    // MARK: Commands from the other threads

    private func handle(_ command: TapCommand) {
        switch command {
        case .perform(let action):
            perform(action)
        case .observe(.typed(let characters)):
            onTyped?(characters)
        case .observe(.mutated):
            onEdited?()
        case .recoverDisabledTap(let mode):
            recoverDisabledTap(mode)
        }
    }

    private func perform(_ action: TapAction) {
        switch action {
        case .acceptWord:
            onAcceptWord?()
        case .acceptAll:
            onAcceptAll?()
        case .cancel:
            onCancel?()
        case .trigger:
            triggerHandled = onTrigger?() ?? false
            refreshSnapshots()
        case .triggerRepeat:
            // A repeat of a trigger this monitor already consumed: swallow it and
            // never start another generation.
            break
        }
    }

    /// The trigger fired from the registered Carbon hot key. This runs one
    /// main-run-loop turn after the Carbon callback returned.
    fileprivate func triggerFromHotKey() {
        guard hotKeyRef != nil, !isSelfActive else { return }
        triggerHandled = onTrigger?() ?? false
        refreshSnapshots()
    }

    private func recoverDisabledTap(_ mode: KeyboardTapMode) {
        let plan = GlobalInputLifecycle.plan(
            isSelfActive: isSelfActive,
            isCompletionActive: isCompletionActive,
            completionsEnabled: completionsEnabled
        )
        switch mode {
        case .typingObserver:
            switch TapLifecycle.recovery(shouldBeInstalled: plan.installsTypingObserver) {
            case .reEnable:
                typingEngine?.reEnable()
            case .remove:
                isTypingObserverInstalled = false
                typingEngine?.stop()
            case .install, .keep:
                break
            }
        case .interaction:
            switch TapLifecycle.recovery(shouldBeInstalled: plan.installsInteractionTap) {
            case .reEnable:
                interactionEngine?.reEnable()
            case .remove:
                isInteractionTapInstalled = false
                interactionEngine?.stop()
            case .install, .keep:
                break
            }
        }
    }

    // MARK: Registered trigger hot key (manual fallback)

    private func registerTriggerHotKey() {
        guard hotKeyRef == nil else { return }
        guard let plan = TriggerHotKeyRegistration.plan(for: triggerShortcut) else {
            NSLog("Cotype: the trigger chord \(triggerShortcut.displayString) cannot be registered.")
            refreshSnapshots()
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            cotypeHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        guard handlerStatus == noErr else {
            NSLog("Cotype: could not install the trigger hot-key handler (\(handlerStatus)).")
            hotKeyHandlerRef = nil
            refreshSnapshots()
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(plan.keyCode),
            plan.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("Cotype: could not register the trigger chord \(triggerShortcut.displayString) (\(status)).")
            if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
            hotKeyHandlerRef = nil
            refreshSnapshots()
            return
        }
        hotKeyRef = ref
        refreshSnapshots()
    }

    private func unregisterTriggerHotKey() {
        let hadHotKey = hotKeyRef != nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
        guard hadHotKey else { return }
        // Reset the repeat latch only when a registration was actually released;
        // while the active tap is the fallback owner the latch must survive a
        // phase change so a held trigger never re-fires.
        triggerHandled = false
        refreshSnapshots()
    }

    // MARK: Passive click monitor (cancel/invalidate only)

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        // Passive: a global monitor observes but can never consume, so a click is
        // never intercepted. It reports a context change, which only ever
        // cancels/invalidates — the interaction machine's `.contextMoved` cannot
        // arm the debounce, so a click can never start a generation.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            hopToMain { self?.onContextMoved?() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Observation

    /// Keep the monitor in sync when the shortcut is changed from the settings UI
    /// (which writes through `TriggerShortcutStore`).
    private func observeShortcutDefaults() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let loaded = TriggerShortcutStore.load()
                if loaded != self.triggerShortcut {
                    self.triggerShortcut = loaded
                }
                let loadedAcceptAll = AcceptAllShortcutStore.load()
                if loadedAcceptAll != self.acceptAllShortcut {
                    self.acceptAllShortcut = loadedAcceptAll
                }
                let loadedAccept = AcceptBehaviorStore.load()
                if loadedAccept != self.acceptBehavior {
                    self.acceptBehavior = loadedAccept
                }
            }
        }
    }

    /// A keyboard-layout change moves the trigger character to a different
    /// physical key: re-resolve it and re-register.
    private func observeKeyboardLayoutChanges() {
        guard layoutObserver == nil else { return }
        layoutObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resolveTriggerKeyCodes()
                self.refreshSnapshots()
                self.applyLifecycle()
            }
        }
    }
}

extension KeyModifiers {
    /// Convert `CGEventFlags` (e.g. `.maskShift`) to the pure modifier snapshot.
    init(from flags: CGEventFlags) {
        self.init(
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift)
        )
    }
}
