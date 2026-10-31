import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @State private var shortcut = TriggerShortcutStore.load()
    @State private var recorder: ShortcutRecorderModel?
    @State private var acceptAllShortcut = AcceptAllShortcutStore.load()
    @State private var acceptAllRecorder: ShortcutRecorderModel?
    @State private var acceptBehavior = AcceptBehaviorStore.load()
    @EnvironmentObject private var reset: SettingsResetCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
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

