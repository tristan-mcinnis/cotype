import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var engineManager: EngineManager
    @ObservedObject var completionController: CompletionController

    @AppStorage("systemPrompt") private var systemPrompt =
        AutocompletePrompt.defaultSystem
    @AppStorage("temperature") private var temperature = 0.0
    @AppStorage(TokenBudget.modeKey) private var tokenMode = TokenBudget.Mode.auto.rawValue
    @AppStorage(TokenBudget.explicitValueKey) private var explicitTokens = TokenBudget.explicitDefault
    @AppStorage(PromptStyle.defaultsKey) private var promptStyle = PromptStyle.default.rawValue
    @AppStorage(BatteryPolicy.pauseOnBatteryKey) private var pauseOnBattery = false
    @AppStorage(BatteryPolicy.pauseInLowPowerModeKey) private var pauseInLowPowerMode = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage(CompletionController.autoSuggestKey) private var autoSuggest = true
    @AppStorage(SuggestionLength.defaultsKey) private var suggestionLength = SuggestionLength.default.rawValue
    @AppStorage(EmojiFilter.defaultsKey) private var allowEmoji = false
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.dark.rawValue
    @StateObject private var launchModel = LaunchAtLoginModel()
    @EnvironmentObject private var reset: SettingsResetCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
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
                SlateDivider()
                SlateRow(
                    title: "Suggest emoji",
                    detail: "Off: a suggestion stops before an emoji."
                ) {
                    InkSwitch(isOn: $allowEmoji)
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
                    SlateField(label: "System prompt") {
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
                    } helper: {
                        SlateProse("Your own writing instructions. They are sent as the system message in the Instructions style only. The Continuation style keeps the measured plain-text prompt and does not send them; it continues any prose it is given.", tertiary: true)
                        if promptStyle == PromptStyle.continuation.rawValue,
                           systemPrompt != AutocompletePrompt.defaultSystem,
                           !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            SlateProse("Saved, but not sent in Continuation. Switch Prompt style to Instructions to apply it. Measured on this model (2026-10-17), Instructions is less accurate on general text than Continuation, so Continuation remains the default; see the README for the dated result.", tertiary: true)
                        }
                    }
                }
                SlateDivider()
                SlateRow(
                    title: "Prompt style",
                    detail: "Continuation keeps writing your text (the measured default). Instructions sends a continuation-only chat message plus your style note and any text after the cursor."
                ) {
                    SlateSegmented(
                        options: PromptStyle.allCases.map { ($0.rawValue, $0 == .continuation ? "Continuation" : "Instructions") },
                        selection: $promptStyle
                    )
                    .frame(width: 260)
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
                SlateRow(
                    title: "Token budget",
                    detail: tokenMode == TokenBudget.Mode.explicit.rawValue
                        ? "Sent as max_tokens, clamped to \(TokenBudget.minimum)–\(TokenBudget.maximum)."
                        : "Follows Suggestion length."
                ) {
                    SlateSegmented(
                        options: [(TokenBudget.Mode.auto.rawValue, "Auto"), (TokenBudget.Mode.explicit.rawValue, "Custom")],
                        selection: $tokenMode
                    )
                    .frame(width: 180)
                }
                if tokenMode == TokenBudget.Mode.explicit.rawValue {
                    SlateDivider()
                    SlateRow(title: "Max tokens") {
                        Stepper("\(TokenBudget.clamped(explicitTokens))", value: $explicitTokens, in: TokenBudget.minimum...TokenBudget.maximum, step: 16)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textSecondary)
                    }
                }
                SlateDivider()
                SlateRow(title: "Effective per request", minHeight: 38) {
                    Text(effectiveBudgetLabel)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
            }

            SettingsCard(title: "Power", subtitle: "Automatic suggestions only; the trigger shortcut always works") {
                SlateRow(
                    title: "Pause automatic suggestions on battery",
                    detail: "Manual trigger still generates."
                ) {
                    InkSwitch(isOn: $pauseOnBattery)
                }
                SlateDivider()
                SlateRow(
                    title: "Pause automatic suggestions in Low Power Mode",
                    detail: "Low Power Mode already asks macOS to reduce background work."
                ) {
                    InkSwitch(isOn: $pauseInLowPowerMode)
                }
            }

            SettingsCard(title: "Note") {
                SlateBlock {
                    SlateProse("The system prompt and prompt style apply to the next completion. Temperature and the token budget take effect immediately for the daemon lane; the in-process model reloads with its own settings.", tertiary: true)
                }
            }
        }
        .onAppear {
            reset.register("Reset to defaults") {
                systemPrompt = AutocompletePrompt.defaultSystem
                temperature = 0.0
                tokenMode = TokenBudget.Mode.auto.rawValue
                explicitTokens = TokenBudget.explicitDefault
                promptStyle = PromptStyle.default.rawValue
                pauseOnBattery = false
                pauseInLowPowerMode = true
                allowEmoji = false
                appearance = AppearancePreference.dark.rawValue
                AppearancePreference.applyCurrent()
            }
        }
    }

    /// The exact number the next request carries, from the same policy the
    /// engines use.
    private var effectiveBudgetLabel: String {
        let length = SuggestionLength(rawValue: suggestionLength) ?? .default
        if tokenMode == TokenBudget.Mode.explicit.rawValue {
            return "\(TokenBudget.clamped(explicitTokens)) tokens (custom)"
        }
        return "\(length.maxTokens) tokens (auto · \(length.title))"
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

