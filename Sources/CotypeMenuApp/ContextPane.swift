import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Context

struct ContextPane: View {
    @AppStorage("context.selectedText") private var contextSelectedText = true
    @AppStorage("context.windowTree") private var contextWindowTree = false
    @AppStorage(GhostTextRenderer.fallbackPreviewKey) private var fallbackPreview = false
    @AppStorage(CompletionController.personalFactsKey) private var personalFacts = ""

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xl) {
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
                SlateRow(
                    title: "Text after the cursor",
                    detail: "Used to avoid duplicate insertions and to abstain inside a word. In the Instructions lane it is also sent as delimited after-cursor context; the Continuation lane does not send it."
                ) {
                    Text("Filtering")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                SlateDivider()
                SlateRow(
                    title: "Anchored preview when the caret is unknown",
                    detail: "Off: no caret position means no preview. On: the suggestion is drawn once at the bottom-left of the focused field, still click-through, and still inserted only when you accept it."
                ) {
                    InkSwitch(isOn: $fallbackPreview)
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
            HStack(spacing: House.Spacing.xs) {
                Text("Unavailable")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                InertToggle()
            }
        }
    }
}

