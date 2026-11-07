import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import Combine
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

/// Menu-bar app delegate. Owns the status item, the completion controller,
/// the global key monitor, and the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?
    private var settingsObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?

    private let personalization = PersonalizationStore()
    private let overrides = AppOverridesStore()
    private let websiteRules = WebsiteRulesStore()
    private let localModels = LocalModelsMonitor()
    private let keyMonitor = GlobalKeyMonitor()
    private let updater = SparkleUpdateController()
    private let menuPanel = MenuBarPanelController()
    /// The menu bar shown while a normal window is open.
    private lazy var settingsMenu = SettingsMenu(showSettings: { [weak self] in self?.openSettings() })
    private var completionController: CompletionController!
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        completionController = CompletionController(
            personalization: personalization,
            overrides: overrides,
            websiteRules: websiteRules,
            notShown: .shared
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "showMenuBarIcon": true,
            "enableCompletions": true,
            // Suggest while typing, like Cotypist. The trigger chord still
            // forces a suggestion on demand.
            CompletionController.autoSuggestKey: true,
            // Privacy: feedback (prefix/completion) content logging defaults to
            // OFF on a fresh install, but disclosed content-free metrics and
            // privacy config are still persisted locally (see PRIVACY.md).
            "learnFromFeedback": false,
            // Dark is the house default; light is first-class.
            AppearancePreference.key: AppearancePreference.dark.rawValue,
        ])
        AppearancePreference.applyCurrent()
        setupMenuPanel()
        setupStatusItem()
        setupKeyMonitor()
        localModels.start()
        subscribe()
        observeMenuBarIconPreference()
        rebuildMenu()
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
    }

    /// Show/hide the status item in response to the persisted preference.
    private func observeMenuBarIconPreference() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let show = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
                self?.updateMenuBarIcon(show)
                // The appearance preference and the daemon-mode toggle both
                // change what the panel shows.
                AppearancePreference.applyCurrent()
                self?.rebuildMenu()
            }
        }
        let initialShow = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        updateMenuBarIcon(initialShow)
    }

    private func updateMenuBarIcon(_ show: Bool) {
        guard let item = statusItem else { return }
        item.isVisible = show
    }

    /// On termination, drain any pending coalesced persistence writes so recorded
    /// metrics / samples are not lost (content-free metrics and privacy config are
    /// written even when content logging is off).
    func applicationWillTerminate(_ notification: Notification) {
        personalization.flush()
        NotShownStore.shared.flush()
    }

    // MARK: - Setup

    /// The status item uses the same I-beam the app icon draws, as a template
    /// image, so icon and menu bar read as one app. The render proof draws it too.
    static func statusGlyph() -> NSImage? {
        let image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Cotype")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: House.Control.statusGlyph, weight: .medium)
            )
        image?.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = Self.statusGlyph()
            button.target = self
            button.action = #selector(toggleMenuPanel)
        }
    }

    /// Clicking the status item toggles the Slate panel; the old NSMenu is gone.
    @objc private func toggleMenuPanel() {
        // The panel's model line ("gemma-it warm", "daemon offline") was read
        // once at launch and never again, so it stayed wrong after the daemon
        // came up or Cotype warmed the model. Re-read it each time the panel
        // opens; the status sink rebuilds the panel when the answer lands.
        if !menuPanel.isVisible { localModels.refresh() }
        menuPanel.toggle(relativeTo: statusItem.button)
    }

    private func setupMenuPanel() {
        menuPanel.model.onToggleCompletions = { [weak self] in self?.toggleEnabled() }
        menuPanel.model.onOpenSettings = { [weak self] in
            self?.menuPanel.close()
            self?.openSettings()
        }
        menuPanel.model.onQuit = { NSApp.terminate(nil) }
    }

    private func setupKeyMonitor() {
        keyMonitor.onTrigger = { [weak self] in self?.completionController.trigger() ?? false }
        keyMonitor.onAcceptWord = { [weak self] in self?.completionController.acceptNextWord() }
        keyMonitor.onAcceptAll = { [weak self] in self?.completionController.accept() }
        keyMonitor.onCancel = { [weak self] in self?.completionController.cancel(recordingRejection: true) }
        keyMonitor.onTyped = { [weak self] chars in self?.completionController.noteTyped(chars) }
        keyMonitor.onEdited = { [weak self] in self?.completionController.noteEdited() }
        keyMonitor.onContextMoved = { [weak self] in self?.completionController.noteContextMoved() }
        keyMonitor.start()
        syncKeyMonitor()
    }

    private func subscribe() {
        localModels.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        completionController.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu(); self?.syncKeyMonitor() }
            .store(in: &cancellables)
        completionController.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        completionController.$completionsEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu(); self?.syncKeyMonitor() }
            .store(in: &cancellables)
        // Tab is taken only while the ghost is on screen, so a hide or a late
        // draw must reach the tap snapshot too.
        completionController.$isGhostVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncKeyMonitor() }
            .store(in: &cancellables)
    }

    private func syncKeyMonitor() {
        keyMonitor.isCompletionActive = completionController.isBusy || completionController.hasPendingCompletion
        keyMonitor.isAcceptReady = completionController.isAcceptKeyReady
        keyMonitor.isSelfActive = settingsWindowController?.window?.isKeyWindow ?? false
        keyMonitor.completionsEnabled = completionController.completionsEnabled
        // The listen-only typing observer is always on while Cotype is enabled;
        // the phase hook installs the narrow active accept/cancel tap (and the
        // registered trigger chord) only from the live phase.
        keyMonitor.applyLifecycle()
    }

    // MARK: - Permissions

    // Permission requests are setup-gated: Cotype explains and asks only when the
    // user opens the Setup pane, never as a blocking alert on launch. The launch-
    // time `promptForPermissionsIfNeeded` alert was removed because it surfaced
    // on every launch until both grants existed and had no way to refresh after
    // the user returned from System Settings.

    private func openPrivacySettings() {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        NSWorkspace.shared.open(URL(string: "\(base)?Privacy_Accessibility")!)
    }

    private func openPrivacyInputMonitoring() {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        NSWorkspace.shared.open(URL(string: "\(base)?Privacy_ListenEvent")!)
    }

    // MARK: - Menu

    /// Push the live state into the menu-bar panel. Everything the old NSMenu
    /// offered is still reachable: the four completion actions are the primary
    /// rows, model lifecycle and Privacy Settings are the second group, and
    /// Settings / Quit sit in the footer well.
    private func rebuildMenu() {
        let phase = completionController.phase
        let localStatus = localModels.status
        let isReady = localStatus.isConfiguredModelWarm
        let statusTitle = isReady ? "\(localStatus.configuredModelAlias) warm"
            : localStatus.isReachable ? "load \(localStatus.configuredModelAlias) in Local Models"
            : "Local Models daemon offline"

        let phaseTitle: String
        switch phase {
        case .idle: phaseTitle = "Idle"
        case .generating: phaseTitle = "Generating…"
        case .awaitingAccept: phaseTitle = "Tab to accept, Esc to dismiss"
        }

        let model = menuPanel.model
        model.completionsEnabled = completionController.completionsEnabled
        model.statusLine = "\(statusTitle) · \(phaseTitle)"
        model.isReady = isReady
        model.phaseLine = phaseTitle
        model.errorLine = completionController.lastError

        model.actions = [
            PanelAction(
                id: "trigger",
                glyph: "sparkles",
                title: "Trigger completion",
                chord: keyMonitor.triggerShortcut.displayString,
                isEnabled: phase != .generating && completionController.completionsEnabled,
                run: { [weak self] in self?.triggerCompletion() }
            ),
            PanelAction(
                id: "acceptWord",
                glyph: "arrow.turn.down.left",
                title: "Accept next word",
                chord: "⇥",
                isEnabled: completionController.isAcceptKeyReady,
                run: { [weak self] in self?.acceptCompletion() }
            ),
            PanelAction(
                id: "acceptAll",
                glyph: "checkmark",
                title: "Accept all",
                chord: keyMonitor.acceptAllShortcut.displayString,
                isEnabled: completionController.isAcceptKeyReady,
                run: { [weak self] in self?.acceptAllCompletion() }
            ),
            PanelAction(
                id: "cancel",
                glyph: "xmark",
                title: "Cancel",
                chord: "esc",
                isEnabled: phase != .idle,
                run: { [weak self] in self?.cancelCompletion() }
            ),
        ]

        // Model lifecycle belongs to the Local Models menu bar.
        model.moreActions = [
            PanelAction(
                id: "modelLifecycle",
                glyph: "shippingbox",
                title: "Load/unload models in Local Models",
                isEnabled: false
            ),
            PanelAction(
                id: "privacy",
                glyph: "hand.raised",
                title: "Open Privacy Settings…",
                run: { [weak self] in
                    self?.menuPanel.close()
                    self?.openPrivacy()
                }
            ),
        ]
    }

    // MARK: - Actions

    private func toggleEnabled() {
        completionController.completionsEnabled.toggle()
    }

    private func triggerCompletion() {
        completionController.trigger()
    }

    private func acceptCompletion() {
        completionController.acceptNextWord()
    }

    private func acceptAllCompletion() {
        completionController.accept()
    }

    private func cancelCompletion() {
        completionController.cancel(recordingRejection: true)
    }

    private func openPrivacy() {
        let alert = NSAlert()
        alert.messageText = "Cotype permissions"
        alert.informativeText = "Cotype needs Accessibility (read/paste text) and Input Monitoring (trigger/accept/cancel keys). Your permission status:"
        alert.alertStyle = .informational

        let ax = AXIsProcessTrusted() ? "Accessibility: granted ✓" : "Accessibility: not granted"
        let post = CGPreflightPostEventAccess() ? "Event posting (paste): granted ✓" : "Event posting (paste): not granted"
        let input = CGPreflightListenEventAccess() ? "Input Monitoring: granted ✓" : "Input Monitoring: not granted"
        alert.informativeText = "\(ax)\n\(post)\n\(input)\n\nKeep Cotype enabled under both categories, then relaunch."
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn { openPrivacySettings() }
        else if response == .alertSecondButtonReturn { openPrivacyInputMonitoring() }
    }

    @objc private func openSettings() {
        if let controller = settingsWindowController, let window = controller.window {
            controller.showWindow(nil)
            present(window)
            return
        }

        let rootView = SettingsView(
            completionController: completionController,
            personalization: personalization,
            overrides: overrides,
            websiteRules: websiteRules,
            updater: updater
        )
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cotype"
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.styleMask = mask
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = House.NSColorToken.surface
        window.appearance = AppearancePreference.current.nsAppearance
        window.setContentSize(NSSize(width: 920, height: 620))
        window.minSize = NSSize(width: 820, height: 540)

        window.isReleasedWhenClosed = false
        window.delegate = self
        let controller = NSWindowController(window: window)
        controller.showWindow(self)
        window.center()
        present(window)
        settingsWindowController = controller
        syncKeyMonitor()

        // Track key/resign so the global key monitor knows when Cotype is self-active.
        settingsObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncKeyMonitor() }
        })
        settingsObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncKeyMonitor() }
        })
    }
}

extension AppDelegate {

    /// A normal window is up: install the menu bar it needs (Edit for its
    /// text fields, Window for minimise and close) and take the keyboard.
    /// An accessory app cannot activate itself on request alone, so
    /// `AppActivation` asks LaunchServices when the request is refused.
    private func present(_ window: NSWindow) {
        if NSApp.mainMenu == nil { NSApp.mainMenu = settingsMenu.makeMenu() }
        AppActivation.becomeRegularApp(showing: window)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// The Settings window is closing: drop its key observers, hand the menu
    /// bar back, and become a menu-bar app again.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindowController?.window {
            settingsWindowController = nil
            for observer in settingsObservers { NotificationCenter.default.removeObserver(observer) }
            settingsObservers.removeAll()
            syncKeyMonitor()
        }
        AppActivation.settleAfterClosing(window)
    }
}
