# Cotypist reverse engineering (2026-10-31)

Target: `/Applications/Cotypist.app`, version 2026.5 (build 81), bundle
`app.cotypist.Cotypist`, arm64 Mach-O, SHA-256
`8cb2475a56de0dcee2d1f9bdc05a6e45b4679e430710d2c7a67dc0c092143529`.

Scope: behaviour only. No Cotypist code or assets were copied. Strings and
symbols from the binary were read as data.

## Method and evidence

| Source | What it gave | Evidence |
|---|---|---|
| REA `open_binary` + `inspect_macho` (summary) | Identity, 87 load commands, 68 dylibs, 3,904 imports | REA Evidence `ev_b262c1800d37d1c2a057775aa68e7705b6636ff6a21d35fcb3e314804faccb4d` |
| `nm -u` imports | Every AX, CGEvent, TIS and text-layout API the app links | listed below |
| `strings -n 6` (17,572 lines) | Swift type names, settings titles and help text, debug defaults | quoted below |
| `defaults read app.cotypist.Cotypist` | Real shortcut defaults on this Mac (key names and two `MASShortcut` archives only) | keyCodes below |
| Info.plist | LSUIElement menu-bar app, macOS 14 floor, bundled llama.cpp (`libllama`, `libggml-metal`) | `Contents/Info.plist`, `Contents/Frameworks` |

Limits: the binary is stripped. REA's deep providers could not decompile it in
this session (Ghidra not configured; the Hopper request timed out on the 14 MB
binary), so no claim below rests on pseudocode. Every claim is an observation
of a linked API, a type name, a settings string, or a stored default, and the
behaviour drawn from it is marked as inference where it is one.

## 1. Inline placement at the caret

Observed:
- Imports `NSAccessibilityBoundsForRangeParameterizedAttribute`,
  `NSAccessibilityAttributedStringForRangeParameterizedAttribute`,
  `NSAccessibilityLineForIndexParameterizedAttribute`,
  `NSAccessibilityInsertionPointLineNumberAttribute`,
  `NSAccessibilitySelectedTextRangeAttribute`, and the text-marker C API
  (`AXTextMarkerRangeCreate`, `AXTextMarkerRangeCopyStart/EndMarker`).
- Imports `kAXFontTextAttribute`, `kAXFontFamilyKey`, `kAXFontNameKey`,
  `kAXFontSizeKey`, `kAXForegroundColorTextAttribute`.
- Types: `CursorAttributes`, `TextMarkerExtractionResult`,
  `TextExtractionApproach`, `CursorRetryPlan`, `LineHeightCache`,
  `CursorLineAlignment`, `CursorLineTextExtractor`, `CursorAnchoredInlinePanel`,
  `SingleCompletionOverlayWindow`, `InlineSuggestionsOverlayWindow`,
  `TextMirrorOverlayWindow`, `CaretView`, per-editor customizers
  (`GhosttyAttributeCustomizer`, `VSCodeForkAttributeCustomizer`,
  `BBEditAttributeCustomizer`, `TerminalAttributeCustomizer`).
- Imports `NSLayoutManager`, `NSTextStorage`, `NSTextContainer`; debug default
  `SingleCompletionOverlay_useLayoutManager`.
- Strings: "Could not determine rect for cursor"; "Show suggestions in a neutral
  grey instead of a translucent shade of the app's own text color";
  per-app "Font size adjustment" ("Scaling factor for font size in overlay
  positioning") and "Vertical alignment offset" ("Vertical pixel offset for
  overlay positioning"); "Enable text mirroring" ("Use a text mirror overlay
  for cursor positioning").
- Strings: Ghostty config paths (`~/.config/ghostty/config`), so terminal fonts
  come from the terminal's own config file, not AX.

Inference: Cotypist draws the ghost in a borderless overlay window at the AX
caret rect, sized to the host's font from `AXAttributedStringForRange`, with
the ghost colour a translucent shade of the host's own text colour. When a
caret rect is missing it retries on a plan (`CursorRetryPlan`) before giving
up. For editors whose geometry is wrong it has two escape hatches: per-app
font-scale and vertical-offset corrections, and a text-mirror mode that
redraws the current line itself (with its own blinking `CaretView`) so the
ghost and the text share one layout.

## 2. Short completions and acceptance by key

Observed:
- Stored defaults on this Mac: `CompletionManager_acceptPartialCompletionShortcut`
  is keyCode 48 (Tab), no modifiers; `CompletionManager_acceptFullCompletionShortcut`
  is keyCode 50 (the grave key above Tab), no modifiers.
- Strings: "Accept Next Word", "Accept Full Completion", and "(Alternate)"
  variants of both; "Tab to accept the whole suggestion, or just the next
  word. Keep typing to dismiss."; "We recommend using Tab or the key above Tab";
  a warning that the chosen key "is a key you write with"; "Disable Tab key"
  per app.
- Strings: "Word-by-word acceptance"; "accepting a single word also includes
  the space after it"; "punctuation directly attached to a word ... is
  accepted along with it".
- Length presets: Short (~1-2 words), Medium (~2-4), Long (~4-7), Very Long
  (~7-10), Ultra Long (~10-15). Help text recommends Medium: "Longer
  completions are slower to generate". Free tier is "locked to the default
  short length".
- Insertion: `CompletionInserter`, `CGEventPostToPid`,
  `CGEventKeyboardSetUnicodeString`, and per-app "String injection chunk
  size (0=paste, 1=char-by-char, >1=chunk size, -1=first word only)",
  "Paste and Match Style", "Backspace after paste".

Inference: Tab takes one word (with its attached punctuation and the
following space) per press; the key above Tab takes the whole suggestion.
Both are consumed only while a ghost is visible. The default length targets
about 2 to 4 words.

## 3. Trigger, speed, model and context

Observed:
- Types `CompletionManagerActor`, `CompletionGenerationDeferral`,
  `CompletionDecodeJob`, `InFlightDecode`, `GenerationExecutor`,
  `LatencyTelemetryCollector`; fields `firstKeystrokeTelemetry`,
  `cycleWaitedOnFirstGeneration`, `isFirstGenerationOfFieldSession`.
- No debounce or delay string; the only wait setting found is for the synonym
  picker ("How long Cotypist waits after your last keystroke before it shows
  the picker").
- "Only show completions on demand" is an opt-in, so the default is
  automatic as you type.
- Model: bundled llama.cpp with Metal; selected model on this Mac
  `gemma-4-E2B-i1-Q4_K_M`; catalog includes Gemma 3/4, Qwen 3, Llama 3.2,
  Phi 4 mini.
- Context: fields `_textUpToCursor`, `_textAfterCursor`, `_screenshotText`,
  `environmentContext`; settings "Use screenshots for context" (Vision OCR),
  "Use clipboard for context", custom instructions, per-app and per-domain
  prompts; prompt sections have budgets (`SectionBudgetOutcome`,
  `SectionTruncation`).
- Gating: "Mid-line completion" (off by default: "Normally Cotypist suggests
  only at the end of a line"), "Don't show completions when typo suspected",
  small-field size thresholds, secure-field subrole, password regex.

Inference: generation starts on each keystroke with in-flight decode
superseded, rather than after a fixed pause. Speed comes from short outputs
and a small local model. Exact timing is unknown (no constant found).

## 4. Per-app exceptions

Observed: `AppOverridesManager`, `AppOverridesStore`, `DomainPattern` with
`Specificity`; per-app switches: enable/disable, disable Tab key, smart quotes,
text mirroring, size thresholds, font size adjustment, vertical offset, grey
colour, mid-line, rich-text editor handling ("editors that focus a hidden
input (e.g. CodeMirror)"), "Improve compatibility with this app", code
editors, terminal mode (`TerminalCompletionMode`, "No TUI agent prompt
detected"). Escape can pause briefly or turn completions off until the app
changes. A shortcut toggles completions per app for a few minutes.

## Gap table: Cotypist vs CoType

CoType read at `ad07579` (main). Status after this pass in the last column.

| Behaviour | Cotypist | CoType before | Status |
|---|---|---|---|
| Caret rect from AX range bounds | BoundsForRange, LineForIndex | Same, plus preceding-char cross-check (`CaretPlacement.swift`) | parity |
| Web/Electron caret | Text markers | Text markers, ancestor walk, deep descendant search | parity |
| Caret not ready yet (laggy Electron) | `CursorRetryPlan` retries | Hides at the first miss | closed: bounded retry |
| Font and baseline match | AXAttributedString font keys, layout manager | AXAttributedString font, line-box fit, text-column inset | parity |
| Ghost colour | Translucent host text colour, grey opt-in | Fixed house ink at 42 % | closed: host colour when exposed |
| Multi-line wrap in field | Inline overlay | Wraps up to 3 lines within field (`InlineGhostLayout`) | parity |
| Per-app font scale / vertical offset | Yes | No | open |
| Text-mirror mode | Yes | No | open |
| Default length | ~2-4 words | 3-6 words (1-3 opt-in) | closed: 1-4 words default |
| Tab accepts next word | Yes, with space and attached punctuation | Yes, same segment rule | parity |
| Accept whole suggestion | Key above Tab, no modifier | Option+Tab | open: kept Option+Tab (backtick is a typing key) |
| Trigger | Automatic, on demand opt-in | Automatic, 120 ms debounce | parity |
| Mid-line | Opt-in | Abstains inside a word with text after | parity |
| Screenshot / clipboard context | Opt-in | Visible window text opt-in, no OCR or clipboard | open |
| Per-app and per-domain rules | Yes | App overrides and website rules | parity |
| Escape | Pause briefly or off until app switch | Short cooldown | parity (one mode) |

## Top 5 gaps by user impact

1. Ghost missing in Slack and other Electron editors when the caret rect is
   not ready on the first read. Fix: bounded retry before hiding.
2. Suggestions longer than the 1 to 4 words a user can take in at a glance.
   Fix: default length 1 to 4 words, prompt and token cap to match.
3. Ghost unreadable where the host's text colour differs from the system
   appearance (dark editor in light mode). Fix: translucent host text colour.
4. No per-app geometry correction for editors that report a scaled or offset
   caret. Open: needs a per-app setting and UI.
5. Accept-all on a single unmodified key. Open: Option+Tab kept on purpose,
   since the grave key is a typing key for code and Markdown.
