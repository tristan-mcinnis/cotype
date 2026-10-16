# Cotype production-readiness plan

Status: **not ready for public release**

This plan assumes Cotype will be distributed directly to other macOS users. A personal-only build can skip notarization and updating, but it still needs the core-output, onboarding, privacy, and reliability fixes.

## Implementation update: 2026-09-25

- Default prompt is now plain-text continuation with token healing, one line,
  one sentence (`ContinuationPrompt`). The unchanged real-model gate
  (`cotype-eval --engine llama`, gemma-4-E2B-it Q4_K_M, 29 cases) went from
  37.9% valid / 2 forbidden (chat prompt, re-measured today) to 75.9% valid /
  0 forbidden, median 117 ms. The gate still fails its 90% bar; it has not
  been weakened.
- Same gate with Qwen2.5-7B base Q4_K_M: 72.4% valid, 0 forbidden, 314 ms.
  The remaining failures on both models are cases with more than one good
  answer where the scorer accepts one reference (`oranges` vs `cherries`,
  `necessary software.` vs `CLI`, `Q3 marketing campaign is` vs `meeting has
  been rescheduled`). 27/29 is needed; the best observed is 22/29.
- `scripts/acceptance.sh` reruns the build, tests, gate, end-to-end test,
  install check, and warm latency; `docs/acceptance-20260925.md` is the manual
  in-app check.

## Implementation update: 2026-08-29

Most engineering blockers in the original baseline below are now implemented:

- The app renders guarded inline ghost text at the Accessibility caret, supports
  continuous type-through, word-by-word Tab acceptance, and cancels stale work
  when the field, caret, selection, or generation changes.
- Canonical streaming sanitization prevents partial control markers from being
  rendered. The unchanged real-model release gate still fails, however: the
  pinned instruction-tuned Gemma 4 E2B reached 58.6% valid with two forbidden
  outputs against a required 90% valid and zero forbidden outputs. The gate has
  not been weakened.
- Setup now downloads, resumes, verifies, installs, removes, and upgrades the
  pinned model in-app. The real engine load path independently verifies size and
  SHA-256 immediately before constructing llama.cpp.
- Content logging defaults off. Sensitive/protected ancestry is checked
  fail-closed, exact insertion focus is revalidated, privacy files are owner-only,
  and frequent metrics/sample persistence runs off the UI thread.
- A Developer ID/Hardened Runtime/notarization/package path and Sparkle 2 signed
  update feed are implemented and testable without credentials. A public release
  still requires real Apple credentials, a hosted HTTPS feed, a clean-Mac install
  and update exercise, and evidence that Gatekeeper reports `Notarized Developer
  ID`.

The remaining release blocker inside the repository is model quality. The
remaining distribution checks require credentials and release infrastructure.
The sections below preserve the original 2026-08-28 findings and acceptance
criteria for traceability; do not read each original blocker as current state.

## Original baseline

Verified on 2026-08-28:

- `swift build` passes.
- `swift test` passes: 53 tests, 0 failures.
- `./scripts/build-app.sh` produces a structurally valid app bundle.
- The real Gemma GGUF loads in-process and uses Metal.
- A 20-case real-model run completed in 8.1 seconds. Median generation latency was 0.303 seconds.
- Real-model quality is not release-grade: 0/20 exact matches, average token F1 0.1110, and model control text such as `<|turn` leaks into candidates.
- Gatekeeper rejects the built app. It is Apple Development-signed, not Developer ID-signed/notarized, and Hardened Runtime is not enabled.

The architecture is sound. The pipeline has clear context, prompt, inference, render, and insert seams. The release blockers are mainly product completion, output correctness, privacy defaults, app-level test coverage, and distribution.

## Release blockers

### P0: Core output can insert model control text

`LlamaCppEngine` waits for a full `<|turn>` delimiter before stopping. When the delimiter spans tokens, a partial delimiter has already been streamed. This happened repeatedly in the real 20-case eval.

Required:

- Buffer enough generated text to detect partial stop sequences before rendering.
- Apply one canonical output sanitizer in both the eval and app paths.
- Remove prompt echo, model turn markers, channel/tool markers, and invalid control text. Do not reuse the current naive `EvalRunner.stripEcho`: it can erase a genuine continuation that happens to match the prompt tail. Sanitize only generated output, hold back a window as long as the longest prompt-tail/control-token boundary, and emit text only after it cannot be part of a forbidden overlap.
- Add token-boundary and legitimate-prefix regression tests for every stop sequence.
- Gate release on zero control-token or prompt-echo leakage across the full golden set and a long fuzz run.

Evidence: `Sources/CotypeCore/Providers/LlamaCppEngine.swift`, especially the stop handling around line 186 and structural prefixes around line 290.

### P0: A new user cannot acquire the model in the app

The downloader exists and is tested, but the product never calls it. A fresh user is told to manually place a multi-GB GGUF in a hidden Application Support directory. `scripts/install.sh` also assumes the exact model already exists in `~/models`.

Required:

- Put model acquisition in Setup.
- Show model name, source, license, download size, disk-space requirement, and expected RAM use before download.
- Show progress, speed, remaining size, pause/resume, retry, cancel, and checksum verification.
- Support interrupted downloads and low-disk recovery.
- Offer Remove/Reinstall after setup.
- Do not mark setup complete until the model loads and passes a one-prompt smoke test.

Evidence: `Sources/CotypeCore/Providers/ModelDownload.swift` and the no-model messages in `Sources/CotypeMenuApp/SettingsPanes.swift` and `CompletionController.swift`.

### P0: Distribution is not production-safe

The build uses Apple Development signing or ad-hoc signing. It has no Hardened Runtime, Developer ID release path, notarization, stapling, update channel, or automated version stamping.

Required for direct distribution:

- Sign app and embedded framework with a stable Developer ID Application identity.
- Enable Hardened Runtime and define the minimum entitlements.
- Notarize, staple, then verify with `codesign`, `spctl`, and `stapler validate`.
- Produce a versioned ZIP or DMG with checksum and release notes.
- Add an update mechanism or a clear, tested manual update flow.
- Preserve app identity so updates do not reset Accessibility/Input Monitoring grants.
- Test install, update, rollback, and uninstall on a clean non-developer Mac.

Evidence: `scripts/build-app.sh` lines 51 and 64-68. Current `spctl -a -vvv -t exec dist/Cotype.app` result: rejected.

### P0: Feedback storage is unsafe by default

The app reads the full focused editor value and stores the full prefix in plaintext for accepted and rejected candidates. Learning defaults on. The log is unbounded and write failures are silent.

Required:

- Default feedback storage off and ask for explicit consent.
- Store the minimum useful context, with a strict character/token cap.
- Never record secure fields, password managers, private browsing fields, or excluded apps. Implement this as a testable `SensitiveContextDetector`: fail closed when the focused AX element has `kAXSecureTextFieldSubrole` or `NSAccessibilityContainsProtectedContentAttribute`, then apply a maintained built-in sensitive-app denylist plus user exclusions. Unknown/unreadable AX state must not be completed or logged.
- Add retention choices: Off, 7 days, 30 days, Keep until deleted.
- Show exactly what is stored and where.
- Add Export and Delete All, with deletion verification.
- Consider aggregate metrics without content as the default.
- Document local storage and any network behavior in a real privacy notice.

Evidence: `AXTextContextProvider.swift:56`, `CompletionController.swift:205-240`, and `PersonalizationStore.swift`.

## Product shape and settings

The current 12-section settings surface contains several unavailable placeholder panes. A production v1 should be smaller and only expose working controls.

A visual review of the current Setup window found a clean base but several unfinished details: excessive empty space below the cards, ambiguous “Idle — loads on demand” copy beside a manual “Load Model” action, inconsistent button alignment, no visible model directory path, and weak contrast on small secondary text. Shrink the window to its content or add a useful footer, make load state/action copy unambiguous, align actions, show the path, and verify text contrast in light/dark and Increase Contrast modes.

### Recommended v1 navigation

1. **Setup**
   - Readiness checklist: Model, Accessibility, shortcut, test completion.
   - Model download/status/removal.
   - Permission status with live refresh and specific recovery steps.
   - A safe built-in text field for the first completion.

2. **General**
   - Enable Cotype.
   - Launch at login.
   - Show menu bar icon.
   - Configurable, layout-aware manual trigger shortcut. Keep pause-based auto-trigger out of v1 because it changes the Input Monitoring and privacy contract.
   - Completion length preset: Short, Balanced, Long.
   - Candidate behavior: preview first, never auto-insert.

3. **Apps**
   - Per-app allow/deny.
   - Default-deny for sensitive app categories.
   - Per-app completion style/system instruction only if users can understand the effect.
   - Clear inherited versus explicit values.

4. **Privacy & Data**
   - What context Cotype reads.
   - Feedback/content logging consent.
   - Retention, Export, Delete All.
   - Excluded apps.
   - “Local inference” status and network-use disclosure.

5. **Advanced**
   - Model details and checksum.
   - Temperature, token cap, context cap, and system prompt with Reset.
   - Diagnostics bundle, log level, and Reset All Settings.
   - Keep technical generation controls out of General.

6. **About & Updates**
   - Version/build, model version, llama.cpp build, update state, licenses, privacy notice, support.

Remove Emoji, Battery, and Labs from stable v1 until they contain working features. Do not use unavailable controls as roadmap advertising inside the product.

### Shortcut decision

The fixed physical backslash key is not production-ready:

- It steals a normal typing character.
- It is unavailable on keyboard layouts where backslash needs Option/Shift.
- Shift+Tab is currently accepted as Tab and can paste a candidate when the user intended to outdent.

Use a configurable, layout-aware shortcut. Prefer a registered modifier chord that minimizes or removes the need to monitor every global keystroke. If Input Monitoring remains necessary, explain why at the moment of request. Accept only unmodified Tab, and always let Shift+Tab pass through.

Evidence: `Sources/CotypeMenuApp/GlobalKeyMonitor.swift:50,105,114,122`.

### Generation defaults

Recommended stable defaults:

- Temperature: `0` for predictable inline completion.
- Length: 32 tokens for Short, 64 for Balanced, 128 for Long.
- Context: cap by tokens and preserve the nearest text around the caret. Do not silently capture/store the whole document.
- Feedback/content logging: Off.
- Per-app mode: enabled for ordinary editors, excluded for known sensitive apps and secure fields.
- Preview: always on. Never auto-insert.
- Model load: lazy, with optional preload at login only after the user sees the RAM impact.

Do not expose 1024-token inline completions as a normal v1 setting. It increases latency, resource use, and runaway-output risk without fitting the interaction.

## User journeys and acceptance tests

### 1. Download and install

Journey:

1. User downloads a notarized package.
2. Gatekeeper opens it without a bypass.
3. Cotype appears once in Applications and starts as a menu-bar app.
4. Reinstall/update preserves settings and TCC identity.

Acceptance:

- Pass on a clean macOS 14 machine and the current macOS release.
- No developer tools or Terminal required.
- Install, update, rollback, and uninstall leave no broken login item.
- Version/build shown in About matches the release artifact.

### 2. First launch and model setup

Journey:

1. Cotype opens Setup, not a blocking permission alert.
2. User sees the product promise, privacy statement, model size, RAM estimate, and setup steps.
3. User downloads and verifies the model.
4. User can retry after network loss, app quit, or low disk.

Acceptance:

- Setup state survives relaunch.
- Progress appears within 250 ms of starting.
- Resume does not corrupt the model.
- Wrong checksum is rejected and explained.
- Model load failure has a recovery action.
- No hidden manual file operation is required.

### 3. Permissions

Journey:

1. Cotype asks only when the user starts the relevant setup step. Remove the current launch-time blocking `promptForPermissionsIfNeeded` alert, which otherwise appears on every launch until both grants exist.
2. It explains what each permission enables and what Cotype can see.
3. The status updates after returning from System Settings.
4. Denial leaves a usable Setup screen and never consumes trigger keys.

Acceptance:

- Denied, later-granted, revoked-while-running, and stale-TCC states all recover.
- No repeated nag loop.
- Secure text fields are never read or completed.
- Permission loss produces one clear, actionable error.

### 4. First completion

Journey:

1. User tries a completion in a safe built-in practice field.
2. Trigger produces a candidate near the text caret.
3. Tab accepts. Escape dismisses. Shift+Tab remains outdent/navigation.
4. The app explains success and then gets out of the way.

Acceptance:

- Candidate is positioned at the caret, not the mouse pointer.
- Trigger is never inserted when handled and is never consumed when not handled.
- Candidate contains no prompt echo or model control tokens.
- Accept inserts exactly once into the original app and preserves clipboard contents.
- Focus change before acceptance cancels safely rather than pasting into another app.
- Cancellation hides the overlay within 150 ms.

### 5. Daily use across apps

Test at minimum:

- TextEdit and Notes: plain text and multiline text.
- Mail and a browser contenteditable field: rich text.
- Xcode and VS Code: code, indentation, tabs, large files.
- Terminal: command line, full-screen, and escape-heavy interaction.
- Slack or another Electron editor.
- Empty field, selected text, middle-of-document infill, very long document, emoji/CJK/RTL text.
- Multiple displays, Spaces, full-screen apps, scaled display, dark/light mode.

Acceptance:

- No wrong-app insertion after focus changes.
- Formatting and clipboard are preserved.
- Disabled apps always pass keys through.
- Unsupported editors fail visibly and safely.
- Rapid trigger/cancel/trigger cycles do not show stale candidates.

### 6. Privacy and personalization

Journey:

1. User explicitly opts in to feedback storage if desired.
2. User can inspect recent records, exclude an app, change retention, export, and delete.
3. A usage summary in Privacy & Data distinguishes shown, accepted, dismissed, canceled, and failed completions. This requires replacing `PersonalizationSample.accepted: Bool` with a versioned outcome enum and migrating existing records before the UI can claim these distinctions.

Acceptance:

- Opt-out writes no content records.
- Delete All removes the data file contents and refreshes every settings pane.
- Retention pruning runs reliably.
- Storage-write failures are surfaced in Settings without interrupting typing.
- Statistics never label acceptance rate as model “accuracy.”

### 7. Failure and recovery

Test:

- Model missing, corrupt, moved, deleted while idle, and incompatible.
- Disk full during download and feedback append.
- App quit during model load and generation.
- Sleep/wake, display change, and low-memory pressure.
- Permission revoked during context read or insertion.
- Clipboard changes during the 300 ms restore window.
- Frontmost app changes during generation and before acceptance.

Acceptance:

- No crash or clipboard loss.
- Errors name the failed step and provide Retry, Open Settings, Reinstall Model, or Report Issue as appropriate.
- The app returns to a known idle state after every failure.

## Evaluation program

The current seed set proves plumbing but is not a valid release gate. Exact match penalizes useful completions that close a code block, while echo stripping can erase genuine output. Replace the single scoreboard with separate suites.

### Suite A: Deterministic correctness

Run on every pull request without a model:

- Pipeline stage ordering and cancellation.
- Output sanitizer across all token boundaries.
- Prompt formatting and context truncation.
- `CompletionController` phase transitions, superseding requests, and stale callback rejection.
- `EngineManager` load/unload/waiter races.
- Shortcut routing, including modifiers and disabled apps.
- AX context splitting using extracted pure functions.
- Clipboard snapshot/restore and focus guards using injected adapters.
- Persistence migration, corruption, retention, export, and deletion.

Gate: all tests pass. No silent integration-test skip in release CI.

### Suite B: Completion quality golden set

Build a versioned set of at least 150 cases:

- 50 prose: email, chat, notes, tone continuation, lists, multilingual text.
- 60 code: Swift, Python, TypeScript, Go, shell, JSON/Markdown, indentation and comments.
- 20 fill-in-the-middle cases.
- 20 abstain/stop cases where no completion or a very short completion is best. Before these become a gate, add an explicit `.noSuggestion` pipeline outcome, produced by EOG-before-content and a deterministic minimum-confidence/validity policy. Score no-suggestion separately from generation failure.

Each case should contain app type, prefix, suffix, accepted alternatives, forbidden substrings, desired maximum length, and rubric tags. Use natural stopping boundaries rather than one arbitrary exact string.

Metrics:

- Valid continuation rate.
- Accepted-alternative/prefix match.
- Syntax/format validity where deterministic.
- Forbidden-output rate: echoes, control tokens, invented speaker turns, code fences, secrets.
- Normalized edit similarity and semantic rubric score.
- Length and over-generation rate.
- Human pairwise preference for prompt/model changes.

Initial release gates:

- 100% free of control tokens and prompt-template leakage.
- At least 95% structurally valid output on deterministic code/data cases.
- No material quality regression from the approved baseline. Define material as more than 2 percentage points overall or 5 points in any major slice.
- Human review approves every high-risk failure and at least 50 randomly sampled cases per release candidate.

Do not use exact match as the headline metric.

### Suite C: Context and safety

Cases:

- Very long documents and cursor near start/middle/end.
- Selected text and non-empty suffix.
- Prompt injection inside document text.
- Password/secure fields detected from AX secure subrole/protected-content attributes, the built-in sensitive-app denylist, and user exclusions. Unit-test the detector independently with allow, deny, and unknown/fail-closed states.
- CJK, emoji, combining characters, RTL, malformed Unicode.
- Cross-request isolation to prove the cleared KV cache does not leak prior text.

Gates:

- Zero context from a previous request appears in a later completion.
- Zero completion or stored feedback from secure/excluded contexts.
- Truncation never breaks UTF-8 or exceeds the KV budget.
- No crash over a seeded fuzz corpus.

### Suite D: Performance and resources

Measure cold and warm behavior on the minimum supported hardware and one current Mac:

- Model load time.
- Time to first token (TTFT), p50/p95.
- Decode tokens/second.
- End-to-end completion latency, p50/p95.
- Cancellation latency.
- Peak resident memory, idle memory, energy impact, and thermal state.
- 30-minute sustained-use test and sleep/wake recovery.

Starting budgets, to revise after hardware baselining:

- Warm TTFT: p50 below 500 ms, p95 below 1.2 s.
- Decode: at least 20 tokens/second on minimum hardware.
- Cancellation/overlay dismissal: below 150 ms.
- No main-thread stall above 100 ms during model load or generation.
- Cold load: visible progress immediately and ready within 15 seconds on minimum hardware.
- No crash or severe thermal state during the sustained test.

The current aggregate latency metric is insufficient because it does not report TTFT, throughput, percentiles beyond median, memory, or cold-load time.

### Suite E: App compatibility

Automate where possible with a small host-editor test app. Run a manual matrix for third-party editors.

Score each app/scenario on:

- Context before/after cursor is correct.
- Overlay placement is correct.
- Trigger/pass-through behavior is correct.
- Accept inserts once in the intended location.
- Cancel inserts nothing.
- Clipboard and formatting remain intact.
- Focus changes are safe.

Gate: 100% on first-party harness cases and no open high-severity issue in the declared supported-app matrix.

### Suite F: Onboarding usability

Run five fresh-user sessions before beta and repeat after major setup changes.

Measure:

- Setup completion rate.
- Time to first successful completion, excluding model transfer time.
- Permission recovery rate.
- Number of times the facilitator must intervene.
- User understanding of local inference and feedback storage.

Gate:

- At least 4/5 users complete setup without help.
- Median time from verified model to first accepted completion below 2 minutes.
- Every participant can correctly state what content is stored by default.

### Suite G: Release, accessibility, and privacy

Release checks:

- Clean-machine install on macOS 14 and current macOS.
- Developer ID, Hardened Runtime, notarization, staple, Gatekeeper.
- Update and rollback preserve permissions/settings.
- Network capture confirms no egress after model setup unless the user invokes an explicit network action.
- VoiceOver, keyboard-only, Reduce Motion, Increase Contrast, light/dark mode, and display scaling.
- Overlay output is available to assistive technology, not only visually drawn.

Gate: all pass, with artifacts attached to the release.

## CI and release lanes

### Every pull request

- Debug and release build.
- All deterministic tests.
- Static formatting/lint if adopted.
- App bundle construction and signature structure check.
- Sanitizer and concurrency stress tests.

### Nightly on a model-equipped Apple Silicon runner

- Full golden set.
- Long-context and fuzz suites.
- 100 rapid cancellation/supersession cycles.
- Performance snapshot with baseline comparison.

### Release candidate

- Full quality/safety suite with pinned model hash, prompt version, llama.cpp build, and sampling config.
- Clean-machine onboarding and app matrix.
- Privacy/network and accessibility checks.
- Notarized artifact verification and update test.
- Human review sign-off.

Machine-readable eval output should include JSON, the full pinned configuration, per-case records, git commit, hardware/OS, load time, TTFT, throughput, memory, and pass/fail thresholds. A command that prints a scoreboard but always exits zero is not a release gate.

## Recommended execution order

### Milestone 1: Core loop trustworthy

1. Immediately default feedback storage off, cap any opted-in prefix, and add the first sensitive-context detector tests so the current personal build stops accumulating full-document plaintext.
2. Fix streamed-output sanitization and add boundary tests.
3. Make shortcut handling layout-aware and prevent Shift+Tab acceptance.
4. Cancel on focus change and verify the insertion target.
5. Move ghost text to the caret.
6. Add app-controller, AX parsing, clipboard, and engine lifecycle tests.

Exit criterion: first-completion journey passes in the declared supported apps with no leaked control text, wrong-target insertion, or default content logging.

### Milestone 2: Fresh-user ready

1. Wire model download/verification into Setup.
2. Replace the permission alert with guided setup and a practice field.
3. Simplify settings to working v1 sections.
4. Finish feedback consent, retention, inspection, export, deletion, and outcome-schema migration after Milestone 1 has already made logging default-off and bounded.
5. Add recovery states and diagnostics.

Exit criterion: 4/5 fresh users reach first accepted completion without help.

### Milestone 3: Releasable and measurable

1. Replace the seeded scoreboard with the versioned eval suites and JSON results.
2. Add CI, nightly model runs, and performance baselines.
3. Add Developer ID/Hardened Runtime/notarization/versioning/update flow.
4. Run clean-machine, accessibility, privacy, compatibility, and sustained-use testing.

Exit criterion: every release gate in this document passes against one pinned release configuration.

## Definition of ready

Cotype is ready when a non-technical user can install it on a clean Mac, understand and grant only the needed permissions, acquire the verified model in-app, complete and safely insert text in supported apps, recover from common failures, inspect/delete any stored data, and update the app without losing permissions. The release must also pass the quality, latency, compatibility, privacy, accessibility, and packaging gates above with a pinned, reproducible configuration.
