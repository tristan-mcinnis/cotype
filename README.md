# Cotype

A native Apple-Silicon macOS 14+ menu-bar app for private, local AI text
completion. Cotype reads the current text field (plus bounded visible text from
the active window, if you turn that on in Context) through Accessibility, asks
Gemma for the next few words (the Suggestion length setting: 1-3 words, 3-6
words, or the rest of the sentence), previews them as ghost text, and inserts
them only when you accept. The Local Models daemon (`local-models`) owns the
registry, weights, and load/unload lifecycle; use the Local Models menu bar, its
face, to warm or unload the model. Cotype streams from the daemon and does not
keep a second multi-GB model in memory.

## Install and use

The local installer builds a signed, version-stamped `Cotype.app`, **quits any
running Cotype**, replaces the app, verifies `codesign` / `rpath` / `Info.plist`,
reports permission preflight status (read-only; it never grants or bypasses TCC),
and relaunches. Model weights are not copied because Local Models owns them:

```bash
./scripts/install.sh             # install (default)
./scripts/install.sh reinstall   # robust, idempotent reinstall (same as default)
./scripts/install.sh repair      # rebuild + reinstall + verify
./scripts/install.sh uninstall   # stop + remove the app (keeps settings/model)

./scripts/install.sh --no-relaunch          # install without opening the app
./scripts/install.sh --with-in-process-model # optional legacy standalone copy
./scripts/install.sh --require-model         # require that legacy fallback copy
```

The installed app is a normal app bundle at `~/Applications/Cotype.app` (override
the location with `--dir` or `COTYPE_INSTALL_DIR`).

The Local Models registry exposes the completion model as `gemma-it`; its current
GGUF lives at:

```text
~/Models/gguf/gemma-4-E2B-it-Q4_K_M.gguf
```

SHA-256 `740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8`.
Cotype connects to the daemon-managed llama-server at
`http://127.0.0.1:8079/v1`. Use the **Local Models** menu bar to warm or unload
`gemma-it`. Cotype Setup reports the daemon and warm-model state but does not
download or duplicate the weights.

The older in-process llama.cpp engine remains as an explicit standalone fallback.
`--with-in-process-model` copies a verified model into Cotype's Application
Support directory; normal installs do not use this lane.

### First-launch permissions

Cotype is a normal app bundle at `~/Applications/Cotype.app`, so macOS can list
it in Privacy & Security.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. If Cotype is absent, press **+** and choose `~/Applications/Cotype.app`.
3. Enable Cotype.
4. Repeat under **Input Monitoring**.
5. Quit and reopen Cotype.

The Setup pane has buttons that open both settings pages and shows the real
permission state.

### Completion controls

- **Ordinary typing** in an eligible text field auto-triggers continuous
  completion: pause for a moment and Cotype predicts the next few words from the
  field (plus visible active-window text, if you turn that on in Context).
  It never consumes your typing, and matching characters **type through** the
  ghost (typing a mismatch dismisses it and regenerates).
- **Editing keys** (backspace, forward delete, return, paste/cut/undo/redo,
  and unmodified Tab with no candidate) invalidate any stale ghost and
  re-debounce from the fresh context — again never consuming the key.
- Press the **trigger chord** (default **Control+Period**, configurable and
  layout-aware) to force a completion. It is consumed only when it actually runs
  one.
- Press **Tab** to accept only the **next word**; press it again to step through
  the rest of the suggestion as ghost text.
- Press the **accept-all chord** (default **Option+Tab**, configurable) to insert
  the **whole** suggestion. Command chords are never intercepted.
- Press **Escape** to cancel during generation or dismiss a candidate and
  briefly pause auto-trigger.
- Use the Cotype menu-bar icon to trigger or cancel a completion and open
  Settings. Use the Local Models menu-bar icon to load or unload `gemma-it`.

Inference streams from the shared model. The prompt is plain-text
continuation (`/v1/completions`): Cotype sends the text before the caret (plus
a short context block with your facts and visible window text) and the model
keeps writing it, stopping at the end of the line or sentence. A trailing space
is token-healed so the model never starts from a lone space token. If
`gemma-it` is cold, Cotype asks Local Models to load it (non-blocking) and says
so; while you type it refreshes the daemon's idle clock every 10 minutes so
the model is not unloaded mid-day. It never loads a private fallback copy. The
older chat prompt stays available with `defaults write com.tristan.cotype
promptStyle instruction`.

## Settings

The native preferences window follows the supplied Cotypist references, with
Setup, General, Context, Personalization, Shortcuts, App Settings, Statistics,
About, and Support sections. Working controls persist. Unsupported
clipboard/screenshot context controls are explicitly marked unavailable rather
than presented as fake paid features. Placeholder Emoji, Battery, and Cotype
Labs sections are absent from the stable build so no unavailable control is
advertised as a roadmap feature.

General settings include a real Launch at Login registration, menu-bar
visibility, global system prompt, temperature, and completion token limit.
App Settings supports per-app enable/disable and system-prompt overrides.

## Architecture

```text
Trigger → Context → Prompt → Inference → Render → Insert
```

| Stage | Protocol | Included implementations |
|---|---|---|
| Trigger | `TriggerProvider` | menu + global `CGEventTap` in the app |
| Context | `ContextProvider` | `StaticContextProvider`, `AXTextContextProvider` |
| Prompt | `PromptBuilder` | `TemplatePromptBuilder` with contextual infill |
| Inference | `InferenceEngine` | Local Models daemon SSE, mock, legacy in-process llama.cpp + Metal |
| Render | `CompletionRenderer` | print/no-op, `GhostTextRenderer` |
| Insert | `CompletionInserter` | direct Accessibility insertion via `CompletionInsertionRouter`, with guarded clipboard fallback |

`CompletionPipeline.events` emits observability events at every stage boundary.
Cotype reads `gemma-it` readiness from the Local Models control-plane registry
and streams from its daemon-managed llama-server. The legacy standalone engine
remains concurrency-guarded and cancellation-aware for explicit fallback use.

## Build, test, and evaluate

```bash
swift build
swift test
./scripts/build-app.sh            # build + sign + version-stamp dist/Cotype.app
./scripts/build-app.sh --info     # print resolved version/signing/framework metadata
./scripts/diagnostics.sh          # safe version/model/hash/permissions report
```

### verify.sh — deterministic gate vs. the model lane

`verify.sh` separates two lanes that fail differently:

- **Deterministic (always required):** `swift build` + `swift test` + app-bundle
  construction/validation. Failure exits non-zero.
- **Model eval (explicit, model-equipped):** runs a real GGUF eval. There is a
  strict distinction: if you **request** the lane (`--model-lane`) but the model
  is missing, it **fails** (never silently passes); if you **don't request** it,
  it reports "skipped" and exits 0. The deterministic gate never needs a model.

```bash
./scripts/verify.sh                 # deterministic; model lane skipped
./scripts/verify.sh --model-lane    # require a model; fail if absent
./scripts/verify.sh --skip-model    # deterministic only
./scripts/verify.sh --mode=ci --json  # machine-readable output for CI
```

Run the real local-model release gate (the FULL seeded eval suite, as a release
gate must):

```bash
./scripts/verify.sh --model-lane
```

For a deliberate smoke run only (never a release gate), cap the case count:

```bash
COTYPE_EVAL_CASES=3 ./scripts/verify.sh --model-lane
```

The eval scoreboard covers Swift, Python, TypeScript, Go, prose, Markdown, and
contextual infill. It reports exact/prefix/token-F1 quality plus average and
median end-to-end generation latency. Model load time remains visible in the
command runtime.

## CI

`.github/workflows/ci.yml` runs its hosted jobs on arm64 `macos-15` while keeping
the app deployment target at macOS 14: a deterministic **build-test** job
(debug + release build, full tests, app-bundle construction + validation,
`verify.sh --skip-model`, and a no-model diagnostics smoke run) on every push/PR;
plus an opt-in **model-eval** job and a **release-package** job on
`workflow_dispatch`. See [`docs/RELEASE.md`](docs/RELEASE.md).

## Licensing and release

- **Cotype itself: all rights reserved. No public license is granted.** Only
  third-party components are covered by their own licenses (llama.cpp and
  Sparkle are MIT; the Gemma model is released under **Apache-2.0**). See
  [`docs/licenses.md`](docs/licenses.md) and the bundled notices under
  `docs/licenses/`.
- A privacy notice lives at [`PRIVACY.md`](PRIVACY.md) and is bundled
  into the app as `Cotype-Privacy.md`.
- **Personal builds are NOT notarized and NOT Developer ID-signed.** The default
  build uses Apple Development (or ad-hoc) signing. The documented opt-in
  Developer ID + Hardened Runtime + notarization path is in
  [`docs/RELEASE.md`](docs/RELEASE.md) and wrapped by `scripts/notarize.sh` and
  `scripts/package-release.sh`, which refuse to run without the credentials.

## Updates

Cotype uses **Sparkle 2** for signed updates. A release build embeds `SUFeedURL`
and `SUPublicEDKey` (base64 Ed25519 public key) in Info.plist and offers **Check for
Updates** plus an **Automatically check for updates** toggle in the About &
Updates pane. Sparkle fetches the signed appcast, verifies the Ed25519 signature
and SHA-256 digest, then downloads, installs, and relaunches — a real updater,
not a manual download. The Sparkle framework (and its bundled `Updater.app` and
XPC services) is embedded and signed by `scripts/build-app.sh`. See
[`docs/RELEASE.md`](docs/RELEASE.md) §5.

**Network:** when a release feed is configured, checking for updates contacts
the appcast URL and downloads the update artifact from it. No completion text,
settings, model data, or telemetry are sent. Dev builds have no feed configured,
so the updater is inert.

## Diagnostics

`./scripts/diagnostics.sh` reports version/build, git commit, signing identity,
llama.cpp build, model path/size/hash, and permission preflight status. It emits
**no sensitive content** — it never reads document text, clipboard contents, or
stored samples.

```bash
./scripts/diagnostics.sh                 # text
./scripts/diagnostics.sh --format json   # machine-readable
./scripts/diagnostics.sh --hash          # include the model SHA-256
./scripts/diagnostics.sh --out report.txt
```

The test suite covers pipeline behavior, settings persistence, legacy feedback
migration, prompt formatting/infill, SSE parsing/error handling, downloader
fresh/resume/overwrite/416/range-mismatch paths, and eval metrics.

## Privacy and storage

Inference stays local when using the menu app. If you explicitly enable content
logging, bounded accepted/dismissed completion samples are stored as JSON Lines
at:

```text
~/Library/Application Support/Cotype/personalization.json
```

Per-app settings live at:

```text
~/Library/Application Support/Cotype/app-overrides.json
```

See `docs/llama-cpp-integration.md` for the pinned XCFramework integration.
