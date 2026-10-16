import Foundation
import Carbon
import CoreGraphics

// MARK: - Pure shortcut model and routing

/// The modifier flags that can qualify a trigger chord. Pure value type so the
/// routing decision is testable without touching AppKit/CoreGraphics.
public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 3)

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public init(_ flags: [ShortcutModifiers]) {
        self.rawValue = flags.reduce(0) { $0 | $1.rawValue }
    }

    /// Whether any modifier is set.
    public var isEmpty: Bool { rawValue == 0 }

    /// A display-friendly name (e.g. "⌃⌥").
    public var displayString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option)  { out += "⌥" }
        if contains(.shift)   { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A configurable, layout-aware manual trigger chord.
///
/// The trigger is a modifier chord over a logical "base key", stored as the
/// unmodified character that key produces in the *current* keyboard layout
/// (e.g. "/", "\\", "."). This makes the shortcut layout-aware: when the user
/// changes layout, Cotype resolves the base key against the active layout
/// instead of depending on a fixed physical key code (the backslash bug).
public struct TriggerShortcut: Codable, Equatable, Sendable {
    public var modifiers: ShortcutModifiers
    /// The unmodified base key label, e.g. "/" or "\\".
    public var key: String

    public init(modifiers: ShortcutModifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// A layout-safe default. Control + Period uses a key present on every
    /// layout and never conflicts with a plain typing character (unlike \).
    public static let `default` = TriggerShortcut(modifiers: [.control], key: ".")

    /// True when a typed chord includes Command, which is reserved for the OS or
    /// the host app and must never be hijacked by Cotype.
    public var isReservedForSystem: Bool { modifiers.contains(.command) }

    /// Human-readable description, e.g. "⌃.".
    public var displayString: String {
        "\(modifiers.displayString)\(key)"
    }
}

/// The pure key-modifier snapshot used by the router. Extracted so routing is
/// testable without `CGEventFlags`.
public struct KeyModifiers: Equatable, Sendable {
    public var command: Bool
    public var control: Bool
    public var option: Bool
    public var shift: Bool

    public init(command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
    }

    /// True when Command, Control, or Option is held (the "reserved" set the
    /// user very likely intends for the host app or OS).
    public var hasReservedMeta: Bool { command || control || option }

    public func matches(_ modifiers: ShortcutModifiers) -> Bool {
        command == modifiers.contains(.command)
            && control == modifiers.contains(.control)
            && option == modifiers.contains(.option)
            && shift == modifiers.contains(.shift)
    }
}

/// The decision the global key monitor makes for a single key event.
public enum ShortcutIntent: Equatable, Sendable {
    /// Unmodified Tab accepted while a candidate is ready — consume, but only
    /// accept the *next word* (do not pass to the editor; the remaining ghost
    /// stays so the user can keep Tab-stepping or type through).
    case acceptWord
    /// The full-suggestion chord (default Option+Tab) accepted while a candidate
    /// is ready — consume, accept the whole suggestion.
    case acceptAll
    /// Escape canceled while a completion is active — consume.
    case cancel
    /// The trigger chord matched — the controller decides whether to consume.
    case trigger
    /// The trigger chord matched on a keyboard-repeat event for an active
    /// completion — consume but do not start a new generation.
    case triggerRepeat
    /// Pass the key through untouched.
    case passthrough
}

/// The configurable chord that accepts the *whole* suggestion (as opposed to
/// Tab, which accepts only the next word). Always a modifier chord over the Tab
/// key so it can never be confused with ordinary typing; Command is never
/// accepted (system/app-reserved).
public struct AcceptAllShortcut: Codable, Equatable, Sendable {
    public var modifiers: ShortcutModifiers

    public init(modifiers: ShortcutModifiers) {
        self.modifiers = modifiers
    }

    /// Safe default: Option+Tab is unbound in most text editors and never
    /// involves Command, so it does not collide with the OS or host-app chords.
    public static let `default` = AcceptAllShortcut(modifiers: [.option])

    /// A chord that includes Command belongs to the host app or macOS and must
    /// never be intercepted.
    public var isReservedForSystem: Bool { modifiers.contains(.command) }

    public var isValid: Bool { !modifiers.isEmpty && !modifiers.contains(.command) }

    public var displayString: String { "\(modifiers.displayString)Tab" }
}

/// Which key accepts a suggestion, and how much of it one press takes.
///
/// Tab is the default, like Cotypist, TabType, and cotabby. Right Arrow is the
/// alternative for apps where Tab has its own job. The key is only taken while
/// a suggestion is showing; otherwise it reaches the app untouched.
public struct AcceptBehavior: Codable, Equatable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case tab
        case rightArrow

        public var keyCode: UInt16 {
            switch self {
            case .tab: return 48
            case .rightArrow: return 124
            }
        }

        public var title: String {
            switch self {
            case .tab: return "Tab"
            case .rightArrow: return "Right Arrow"
            }
        }

        public var glyph: String {
            switch self {
            case .tab: return "Tab"
            case .rightArrow: return "→"
            }
        }
    }

    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// One press inserts the next word; press again for more.
        case nextWord
        /// One press inserts the whole suggestion.
        case wholeSuggestion

        public var title: String {
            switch self {
            case .nextWord: return "Next word"
            case .wholeSuggestion: return "Whole suggestion"
            }
        }
    }

    public var key: Key
    public var mode: Mode

    public init(key: Key = .tab, mode: Mode = .nextWord) {
        self.key = key
        self.mode = mode
    }

    public static let `default` = AcceptBehavior()
}

public enum AcceptBehaviorStore {
    public static let defaultsKey = "acceptBehavior"

    public static func load(userDefaults: UserDefaults = .standard) -> AcceptBehavior {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let behavior = try? JSONDecoder().decode(AcceptBehavior.self, from: data)
        else { return .default }
        return behavior
    }

    public static func save(_ behavior: AcceptBehavior, userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(behavior) else { return }
        userDefaults.set(data, forKey: defaultsKey)
    }
}

/// Pure routing decision for the global key monitor.
///
/// The monitor feeds raw CGEvent values into this; the decision is fully
/// deterministic and testable. The trigger's base key is resolved against the
/// *current* layout via `pressedBaseKey`, so the routing is layout-aware.
public struct GlobalKeyRouter {

    /// The configured trigger chord.
    public var trigger: TriggerShortcut
    /// The chord that accepts the whole suggestion (default Option+Tab).
    public var acceptAll: AcceptAllShortcut
    /// The accept key and how much one press takes.
    public var accept: AcceptBehavior
    /// Resolves the unmodified character a pressed key produces in the current
    /// keyboard layout. Injected so tests can stub the layout.
    public var pressedBaseKey: (UInt16) -> String?

    public init(
        trigger: TriggerShortcut = .default,
        acceptAll: AcceptAllShortcut = .default,
        accept: AcceptBehavior = .default,
        pressedBaseKey: @escaping (UInt16) -> String? = KeyboardLayoutResolver.unmodifiedBaseKey(forKeyCode:)
    ) {
        self.trigger = trigger
        self.acceptAll = acceptAll
        self.accept = accept
        self.pressedBaseKey = pressedBaseKey
    }

    public static let tabKey: UInt16 = 48
    public static let escapeKey: UInt16 = 53

    /// Route a single key event.
    public func route(
        keyCode: UInt16,
        modifiers: KeyModifiers,
        isSelfActive: Bool,
        isCompletionActive: Bool,
        isAcceptReady: Bool,
        isRepeat: Bool,
        triggerHandled: Bool = false
    ) -> ShortcutIntent {
        // Never hijack keys bound to Cotype's own settings UI.
        if isSelfActive { return .passthrough }

        // Accept next word: Tab only. Unmodified Tab (no Command/Control/Option
        // and no Shift — Shift+Tab must pass through as outdent/navigation).
        if keyCode == accept.key.keyCode, isAcceptReady, !modifiers.hasReservedMeta, !modifiers.shift {
            return accept.mode == .wholeSuggestion ? .acceptAll : .acceptWord
        }

        // Accept all: the full-suggestion chord over the Tab key, only while a
        // candidate is ready. Never Command (system/app-reserved).
        if keyCode == accept.key.keyCode, isAcceptReady, acceptAll.isValid, modifiers.matches(acceptAll.modifiers) {
            return .acceptAll
        }

        // Cancel: Escape, but never swallow Command/Control/Option combos.
        if keyCode == Self.escapeKey, isCompletionActive, !modifiers.hasReservedMeta {
            return .cancel
        }

        // Trigger: the configured chord, resolved against the current layout.
        // Command chords belong to the host app or OS and are never intercepted,
        // even if corrupt or older persisted settings contain one.
        if !trigger.isReservedForSystem,
           !trigger.modifiers.isEmpty,
           let baseKey = pressedBaseKey(keyCode),
           baseKey == trigger.key,
           modifiers.matches(trigger.modifiers) {
            if isRepeat {
                // A trigger repeat is swallowed only when the initial press was
                // actually consumed by this monitor; otherwise it passes through
                // so a gated/passed-through trigger never re-gets gated on repeat.
                return triggerHandled ? .triggerRepeat : .passthrough
            }
            return .trigger
        }

        return .passthrough
    }

    // MARK: - Layout helpers (testable)

    /// Convert a trigger into the set of key codes that resolve to it in the
    /// current layout. Used by the recorder to validate a chosen chord.
    public static func resolvedKeyCodes(for trigger: TriggerShortcut, baseKey: (String) -> [UInt16]) -> [UInt16] {
        baseKey(trigger.key)
    }
}

// MARK: - Typing observation (pure)

/// Pure rule for whether a resolved character is ordinary typing that should be
/// *observed* (never consumed) by the interaction loop.
///
/// Requires exactly one printable grapheme and no reserved meta (Command/
/// Control/Option). Excludes control chars (including tab/newline), C1 controls,
/// and Apple function/private-use keys (arrows, F-keys), so those never feed the
/// loop or trigger a debounce.
public func isOrdinaryTypingText(_ text: String, hasReservedMeta: Bool) -> Bool {
    guard !hasReservedMeta else { return false }
    guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
    let value = scalar.value
    if value < 0x20 { return false }
    if (0x7F...0x9F).contains(value) { return false }
    if (0xF700...0xF8FF).contains(value) { return false }
    return true
}

/// How a pass-through key event mutates the edited context. Pure and testable;
/// the global monitor defers the result to the next main-loop turn so the host
/// editor has already applied the edit (fixes re-rendering at the old caret).
public enum EditObservation: Equatable, Sendable {
    /// Printable character typed at the caret — drives the type-through/debounce
    /// loop (may match the ghost).
    case typed(String)
    /// A non-printable mutation (backspace/delete, return, paste/cut/undo/redo,
    /// unmodified Tab with no candidate) — invalidates any stale ghost/generation
    /// and debounces from the fresh context.
    case mutated
}

/// Classify a key event that passed through untouched into an edit observation.
/// Returns nil for keys that do not mutate the edited context (e.g. a bare
/// modifier, an arrow, or a non-mutating Command chord). Pure and testable.
///
/// Command chords are **never hijacked** — paste/cut/undo/redo are only *observed*
/// as mutations, and the key still reaches the host app unchanged.
public func classifyEditorObservation(
    keyCode: UInt16,
    modifiers: KeyModifiers,
    text: String
) -> EditObservation? {
    // Mutating Command chords: observe (invalidate + re-debounce) but never block.
    if modifiers.command {
        // V = paste (9), X = cut (7), Z = undo/redo (6).
        if keyCode == 9 || keyCode == 7 || keyCode == 6 { return .mutated }
        return nil
    }
    // Control/Option chords are app-level shortcuts, not ordinary edits.
    if modifiers.control || modifiers.option { return nil }

    // Non-printable editing / caret-move keys. Unmodified Tab with no candidate is
    // treated as an edit-context mutation so a stale ghost never lingers after
    // navigation. Shift+Tab stays outdent/navigation and is never observed.
    switch keyCode {
    case 51, 117: return .mutated          // Backspace, Forward Delete
    case 36, 76: return .mutated           // Return, keypad Enter
    case 48: return modifiers.shift ? nil : .mutated  // unmodified Tab (no candidate)
    // Caret/selection navigation (arrows, Home, End, Page Up/Down) moves the
    // insertion point within the field: invalidate so no ghost sticks at the
    // old caret while the key is not consumed.
    case 115, 119, 116, 121, 123, 124, 125, 126: return .mutated
    default: break
    }

    if isOrdinaryTypingText(text, hasReservedMeta: modifiers.hasReservedMeta) {
        return .typed(text)
    }
    return nil
}

// MARK: - Persistence

/// Loads and saves the trigger shortcut in `UserDefaults`. A single keyed value
/// so the General pane and the key monitor share one source of truth.
public enum TriggerShortcutStore {
    public static let defaultsKey = "triggerShortcut"

    public static func load(userDefaults: UserDefaults = .standard) -> TriggerShortcut {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(TriggerShortcut.self, from: data),
              !shortcut.modifiers.isEmpty,
              !shortcut.isReservedForSystem else { return .default }
        return shortcut
    }

    public static func save(_ shortcut: TriggerShortcut, userDefaults: UserDefaults = .standard) {
        guard !shortcut.modifiers.isEmpty, !shortcut.isReservedForSystem,
              let data = try? JSONEncoder().encode(shortcut) else { return }
        userDefaults.set(data, forKey: defaultsKey)
    }
}

/// Loads and saves the full-suggestion accept chord in `UserDefaults`, sharing
/// the `TriggerShortcut` value shape so both the monitor and the Shortcuts pane
/// have one source of truth.
public enum AcceptAllShortcutStore {
    public static let defaultsKey = "acceptAllShortcut"

    public static func load(userDefaults: UserDefaults = .standard) -> AcceptAllShortcut {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(AcceptAllShortcut.self, from: data),
              shortcut.isValid else { return .default }
        return shortcut
    }

    public static func save(_ shortcut: AcceptAllShortcut, userDefaults: UserDefaults = .standard) {
        guard shortcut.isValid, let data = try? JSONEncoder().encode(shortcut) else { return }
        userDefaults.set(data, forKey: defaultsKey)
    }
}

// MARK: - Live keyboard-layout resolution

/// Resolves base characters for physical key codes using the current macOS
/// keyboard layout, so the trigger chord is layout-aware (unlike the old,
/// hard-coded physical-backslash key code 42).
public enum KeyboardLayoutResolver {

    /// The unmodified base character produced by `keyCode` in the current layout.
    public static func unmodifiedBaseKey(forKeyCode keyCode: UInt16) -> String? {
        guard let layoutData = currentLayoutData() else { return nil }
        return layoutData.withUnsafeBytes { bytes -> String? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let layout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState = UInt32(0)
            let (status, chars) = keycodeToCharacters(
                layout, keyCode: keyCode,
                modifiers: 0, deadKeyState: &deadKeyState,
                count: 4
            )
            guard status == noErr, !chars.isEmpty else { return nil }
            return chars
        }
    }

    /// The unmodified base characters for every key in the current layout keyed
    /// by key code. Used by the recorder/settings UI.
    public static func allBaseKeys() -> [UInt16: String] {
        guard let layoutData = currentLayoutData() else { return [:] }
        return layoutData.withUnsafeBytes { bytes -> [UInt16: String] in
            guard let baseAddress = bytes.baseAddress else { return [:] }
            let layout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            var result: [UInt16: String] = [:]
            for keyCode: UInt16 in 0...127 {
                var deadKeyState = UInt32(0)
                let (status, chars) = keycodeToCharacters(
                    layout, keyCode: keyCode,
                    modifiers: 0, deadKeyState: &deadKeyState,
                    count: 4
                )
                if status == noErr, !chars.isEmpty {
                    result[keyCode] = chars
                }
            }
            return result
        }
    }

    /// Find the key code(s) in the current layout that produce `character`.
    public static func keyCodes(forCharacter character: String) -> [UInt16] {
        allBaseKeys().compactMap { keyCode, base in base == character ? keyCode : nil }
    }

    // MARK: - UCKeyTranslate plumbing

    private static func currentLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        // Copy the property bytes. Returning a pointer into the input source's
        // CFData would leave a dangling pointer once `source` is released.
        return Data(bytes: bytes, count: CFDataGetLength(data))
    }

    private static func keycodeToCharacters(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: UInt16,
        modifiers: UInt32,
        deadKeyState: inout UInt32,
        count: Int
    ) -> (OSStatus, String) {
        var chars = [UniChar](repeating: 0, count: count)
        var length = 0
        let keyboardType = UInt32(LMGetKbdType())
        let status = withUnsafeMutablePointer(to: &deadKeyState) { deadKey in
            chars.withUnsafeMutableBufferPointer { buffer in
                UCKeyTranslate(
                    layout,
                    keyCode,
                    0,             // key-down
                    modifiers,     // modifier flags (currently 0)
                    keyboardType,
                    0,             // kUCKeyboardLayoutType
                    deadKey,
                    count,
                    &length,
                    buffer.baseAddress!
                )
            }
        }
        let string = length > 0 ? String(utf16CodeUnits: chars, count: length) : ""
        return (status, string)
    }
}

// MARK: - Global input architecture (pure)
//
// Cotype's global input is three paths, and which one is live is a pure
// function of app state:
//
//   1. an always-on, **listen-only** keyboard observer (`.listenOnly`
//      `CGEventTap`) reports typing and edits for the automatic suggestion
//      loop. It can never block or consume an event.
//   2. a narrow **active** accept/cancel tap (`.defaultTap`) exists only while
//      a generation or a candidate is live, and only ever consumes Tab, the
//      accept-all chord, Escape, or (as a fallback) the trigger chord.
//   3. a registered Carbon hot key keeps the manual trigger available as an
//      always-available fallback.
//
// A passive `NSEvent` click monitor can only cancel/invalidate; it can never
// start a generation.
//
// Nothing in this section touches AppKit, `UserDefaults`, Accessibility, or the
// keyboard layout table; the host resolves those and passes plain values in.
// Every event callback is O(1) because each decision below is a pure function
// of an immutable snapshot.

extension ShortcutModifiers {
    /// The `RegisterEventHotKey` modifier mask for this set (Carbon `cmdKey`,
    /// `shiftKey`, `optionKey`, `controlKey`).
    public var carbonHotKeyModifiers: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= UInt32(cmdKey) }
        if contains(.shift)   { mask |= UInt32(shiftKey) }
        if contains(.option)  { mask |= UInt32(optionKey) }
        if contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}

/// A trigger chord resolved to something `RegisterEventHotKey` accepts.
public struct CarbonHotKeyPlan: Equatable, Sendable {
    /// The virtual key code that produces the trigger's base character in the
    /// active keyboard layout.
    public var keyCode: UInt16
    /// The Carbon modifier mask (`controlKey`, `optionKey`, …).
    public var carbonModifiers: UInt32

    public init(keyCode: UInt16, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

/// Resolves the configured, layout-aware `TriggerShortcut` into a Carbon hot
/// key. `keyCodes` is injected (defaulting to the live layout) so the resolution
/// is testable without a live keyboard layout.
public enum TriggerHotKeyRegistration {

    public static func plan(
        for trigger: TriggerShortcut,
        keyCodes: (String) -> [UInt16] = { KeyboardLayoutResolver.keyCodes(forCharacter: $0) }
    ) -> CarbonHotKeyPlan? {
        // A bare, modifierless key would steal ordinary typing, and a Command
        // chord belongs to the host app or macOS. Neither is ever registered.
        guard !trigger.modifiers.isEmpty, !trigger.isReservedForSystem else { return nil }
        // A character can sit on more than one physical key; the lowest key code
        // keeps registration deterministic across layouts.
        guard let keyCode = keyCodes(trigger.key).min() else { return nil }
        return CarbonHotKeyPlan(
            keyCode: keyCode,
            carbonModifiers: trigger.modifiers.carbonHotKeyModifiers
        )
    }
}

// MARK: - Synthetic events (fail open, checked first)

/// Tagging for keyboard events Cotype posts itself (for example the paste that
/// inserts a completion). Both callbacks check this **first**: a tagged event is
/// never consumed by the active tap and never observed as a user edit by the
/// listen-only observer. Synthetic events fail open.
public enum SyntheticEventTag {
    /// `'CTYP'`; `CGEvent`'s default `eventSourceUserData` is 0, so a real input
    /// event can never collide with the marker.
    public static let marker: Int64 = 0x4354_5950

    public static func isTagged(sourceUserData: Int64) -> Bool {
        sourceUserData == marker
    }
}

// MARK: - Lifecycle (two taps + a registered hot key)

/// Which global input paths should be live for a given app state.
public struct InputLifecyclePlan: Equatable, Sendable {
    /// The always-on, listen-only keyboard observer.
    public var installsTypingObserver: Bool
    /// `RegisterEventHotKey` owns the manual trigger chord.
    public var registersTriggerHotKey: Bool
    /// The narrow active accept/cancel tap.
    public var installsInteractionTap: Bool
    /// The passive click monitor (cancel/invalidate only).
    public var monitorsClicks: Bool

    public init(
        installsTypingObserver: Bool,
        registersTriggerHotKey: Bool,
        installsInteractionTap: Bool,
        monitorsClicks: Bool
    ) {
        self.installsTypingObserver = installsTypingObserver
        self.registersTriggerHotKey = registersTriggerHotKey
        self.installsInteractionTap = installsInteractionTap
        self.monitorsClicks = monitorsClicks
    }
}

/// The pure lifecycle rule for Cotype's global input.
///
/// Automatic-first: the listen-only observer is installed for as long as
/// completions are enabled, so suggestions can follow typing. It is
/// non-blocking, so it never needs to be scoped to a phase; Cotype's own window
/// is filtered by the observer's snapshot instead of by uninstalling the tap.
/// The active tap stays narrow: only a live generation or candidate installs it.
public enum GlobalInputLifecycle {

    public static func plan(
        isSelfActive: Bool,
        isCompletionActive: Bool,
        completionsEnabled: Bool
    ) -> InputLifecyclePlan {
        // Nothing is watched at all while completions are off.
        guard completionsEnabled else {
            return InputLifecyclePlan(
                installsTypingObserver: false,
                registersTriggerHotKey: false,
                installsInteractionTap: false,
                monitorsClicks: false
            )
        }
        return InputLifecyclePlan(
            installsTypingObserver: true,
            registersTriggerHotKey: !isSelfActive,
            installsInteractionTap: InteractionTapLifecycle.shouldInstall(
                isSelfActive: isSelfActive,
                isCompletionActive: isCompletionActive
            ),
            monitorsClicks: true
        )
    }
}

/// The concrete instruction for a `CGEventTap`.
public enum TapInstruction: Equatable, Sendable {
    case install
    case remove
    case keep
    /// The system disabled the tap; turn it back on without rebuilding it.
    case reEnable
}

/// The pure lifecycle rule shared by both taps.
public enum TapLifecycle {

    public static func instruction(isInstalled: Bool, shouldBeInstalled: Bool) -> TapInstruction {
        switch (isInstalled, shouldBeInstalled) {
        case (false, true): return .install
        case (true, false): return .remove
        case (true, true), (false, false): return .keep
        }
    }

    /// The system can disable a tap (callback timeout, secure input) without
    /// asking. Recovering deterministically means re-enabling it when it is
    /// still wanted and tearing it down when it is not.
    public static func recovery(shouldBeInstalled: Bool) -> TapInstruction {
        shouldBeInstalled ? .reEnable : .remove
    }

    /// The keyboard-only event mask used by both taps. No mouse event type
    /// appears here, so neither tap can intercept a click; a click is observed
    /// by the passive `NSEvent` monitor instead.
    public static let eventMask: CGEventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
}

/// The active accept/cancel tap's install predicate.
public enum InteractionTapLifecycle {
    /// The tap exists only while a generation or a candidate is live, and never
    /// while Cotype's own window is key.
    public static func shouldInstall(isSelfActive: Bool, isCompletionActive: Bool) -> Bool {
        !isSelfActive && isCompletionActive
    }
}

// MARK: - Active accept/cancel tap + listen-only tap snapshots (pure)

/// An action the active tap asks the main actor to perform.
public enum TapAction: Equatable, Sendable {
    case acceptWord
    case acceptAll
    case cancel
    case trigger
    case triggerRepeat
}

/// What the active tap does with one key-down event.
public enum TapRouteDecision: Equatable, Sendable {
    /// Swallow the key; `perform` is enqueued on the main actor.
    case consume(TapAction)
    /// Forward the key untouched. The listen-only observer, which sits behind
    /// the active tap in the tap chain, sees it and reports any edit.
    case pass
}

/// Everything the active tap callback needs, resolved on the main actor
/// *before* the callback runs. Reading this snapshot is the only shared state
/// the callback touches (under a lock); it performs no layout lookup, no
/// `UserDefaults` read, no Accessibility call, and no controller call.
public struct TapRouteSnapshot: Equatable, Sendable {
    public var isSelfActive: Bool
    public var isCompletionActive: Bool
    public var isAcceptReady: Bool
    public var trigger: TriggerShortcut
    public var acceptAll: AcceptAllShortcut
    public var accept: AcceptBehavior
    /// The key codes that currently resolve to the trigger's base key in the
    /// active layout, precomputed so the callback only does a set lookup.
    public var triggerKeyCodes: Set<UInt16>
    /// True while this monitor consumed the trigger press, so its key repeat is
    /// swallowed instead of starting another generation.
    public var triggerHandled: Bool
    /// True while the registered Carbon hot key is installed and therefore owns
    /// the manual trigger. The active tap then forwards the trigger chord so
    /// exactly one path fires it. When registration is unavailable the tap
    /// becomes the fallback owner and consumes the chord itself.
    public var triggerOwnedByHotKey: Bool

    public init(
        isSelfActive: Bool,
        isCompletionActive: Bool,
        isAcceptReady: Bool,
        trigger: TriggerShortcut,
        acceptAll: AcceptAllShortcut,
        triggerKeyCodes: Set<UInt16>,
        triggerHandled: Bool,
        triggerOwnedByHotKey: Bool,
        accept: AcceptBehavior = .default
    ) {
        self.accept = accept
        self.isSelfActive = isSelfActive
        self.isCompletionActive = isCompletionActive
        self.isAcceptReady = isAcceptReady
        self.trigger = trigger
        self.acceptAll = acceptAll
        self.triggerKeyCodes = triggerKeyCodes
        self.triggerHandled = triggerHandled
        self.triggerOwnedByHotKey = triggerOwnedByHotKey
    }

    /// Couples the pure `GlobalKeyRouter` to the precomputed layout map: the
    /// base-key lookup is an O(1) set membership test, so no keyboard-layout
    /// table is ever copied inside the tap callback.
    ///
    /// Fail-open contracts: Shift+Tab and every Command chord always pass, a
    /// tagged (synthetic) event always passes, and the trigger chord passes
    /// whenever the registered hot key owns it.
    public func route(
        keyCode: UInt16,
        modifiers: KeyModifiers,
        isRepeat: Bool,
        isSynthetic: Bool = false
    ) -> TapRouteDecision {
        guard !isSelfActive, !isSynthetic else { return .pass }

        let router = GlobalKeyRouter(trigger: trigger, acceptAll: acceptAll, accept: accept) { pressed in
            triggerKeyCodes.contains(pressed) ? trigger.key : nil
        }
        let intent = router.route(
            keyCode: keyCode,
            modifiers: modifiers,
            isSelfActive: false,
            isCompletionActive: isCompletionActive,
            isAcceptReady: isAcceptReady,
            isRepeat: isRepeat,
            triggerHandled: triggerHandled
        )

        switch intent {
        case .acceptWord: return .consume(.acceptWord)
        case .acceptAll: return .consume(.acceptAll)
        case .cancel: return .consume(.cancel)
        case .trigger:
            return triggerOwnedByHotKey ? .pass : .consume(.trigger)
        case .triggerRepeat:
            return triggerOwnedByHotKey ? .pass : .consume(.triggerRepeat)
        case .passthrough:
            return .pass
        }
    }

    // MARK: - Listen-only observation (pure)

    /// The observation the always-on, listen-only observer should report for one
    /// key-down, or nil when there is nothing to report.
    ///
    /// The observer can never consume an event, so this only decides which
    /// observation to dispatch. It uses the *same* snapshot as the active tap,
    /// which makes the split deterministic: a key that another path consumes
    /// (unmodified Tab with a candidate ready, the accept-all chord, Escape, or
    /// the trigger chord) is never also reported as a user edit, regardless of
    /// which tap macOS happens to run first.
    public func typingObservation(
        keyCode: UInt16,
        modifiers: KeyModifiers,
        text: String,
        isRepeat: Bool = false,
        isSynthetic: Bool = false
    ) -> EditObservation? {
        // Never observe Cotype's own window or Cotype's own synthetic events.
        guard !isSelfActive, !isSynthetic else { return nil }
        // Never observe a key another path owns.
        guard !isConsumedByAnotherPath(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) else {
            return nil
        }
        return classifyEditorObservation(keyCode: keyCode, modifiers: modifiers, text: text)
    }

    /// True when another input path consumes this key press.
    ///
    /// Consuming paths are the registered trigger hot key (which owns the
    /// chord wherever the tap is) and the active tap: unmodified Tab while a
    /// candidate is ready, the accept-all chord, Escape while an interaction is
    /// live, and the trigger chord when the hot key is unavailable.
    public func isConsumedByAnotherPath(
        keyCode: UInt16,
        modifiers: KeyModifiers,
        isRepeat: Bool = false
    ) -> Bool {
        if triggerOwnedByHotKey, matchesTriggerChord(keyCode: keyCode, modifiers: modifiers) {
            return true
        }
        // Only the active tap can own Tab/accept-all/Escape. When no interaction
        // is live there is no tap to consume anything, so the key reaches the
        // editor and must be observed.
        guard InteractionTapLifecycle.shouldInstall(
            isSelfActive: isSelfActive,
            isCompletionActive: isCompletionActive
        ) else {
            return false
        }
        switch route(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) {
        case .consume:
            return true
        case .pass:
            return false
        }
    }

    private func matchesTriggerChord(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        guard !trigger.modifiers.isEmpty, !trigger.isReservedForSystem else { return false }
        guard triggerKeyCodes.contains(keyCode) else { return false }
        return modifiers.matches(trigger.modifiers)
    }
}
