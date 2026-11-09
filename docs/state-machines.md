# Cotype state-machine audit

Audited 2026-11-09 against base commit `8b3009f`, with three independent source
reviews covering completion/macOS, menu/settings/model status, and core/release.
This is a source-review report, not a runtime state registry. Source and tests
remain authoritative. Paths below are relative to `Sources/` unless prefixed
with `scripts/`. Static preferences are included only where they drive a
lifecycle. The inventory includes explicit machines so their implicit companions
and competing state owners are visible.

## Decision

Keep the existing focused machines. Enforce **request ownership after every
suspension** and **terminal stream events** at their existing interfaces. A
universal state-machine framework would add migration risk without resolving
these ownership bugs.

Three changes from this audit:

| Transition | Previous behavior | Enforced behavior | Regression evidence |
| --- | --- | --- | --- |
| Old insertion returns after a new request starts | Success could replace the new focus target or clear its identity; failure could clear identity and replace status | Only the owning render epoch updates request identity/status; old outcomes still record their own metrics | `ControllerInteractionTests.testOld{Full,Stepped}Accept{Success,Failure}PreservesNewRequest` |
| Cancel read A, start B, A finishes | A cleared B's task handle; B could no longer be cancelled/coalesced | A read identity owns its handle until retired | `LocalModelsStatusTests.testLateCancelledReadCannotClearReplacement` |
| Provider emits `.end`, then tokens or an error | Consumer kept reading after the terminal event | First `.end` freezes the result and exits generation | `PipelineTests.testEndFreezesRenderedAndAcceptedCandidate`, `testErrorAfterEndCannotInvalidateCompletedSuggestion` |

UX: a finished preview stays stable, new suggestions retain their correct editor
target, and refresh cancellation remains effective. DX: ownership checks live at
the three effect-completion interfaces. AX: the same rules are documented here,
in the stream contract, and executable regressions. No text is inserted without
acceptance; no model lifecycle policy or permission is changed.

## Completion and platform machines

| Machine | States and transitions | Owner/source and invariant |
| --- | --- | --- |
| Typing interaction | idle → debounce → generating → awaiting accept; dismissal → cooldown; edits invalidate | `CotypeMacOS/CompletionInteraction.swift`; only acceptance emits commit, manual and automatic lanes remain distinct |
| Generation supersession | idle → generating → candidate/idle; begin/cancel/accept advances generation | `CotypeMacOS/CompletionFlow.swift`; old callbacks cannot alter the live generation |
| Published completion | interaction state → phase and candidate projections | `CotypeMacOS/CompletionController.swift`, `refreshFromInteraction`; UI should agree with interaction |
| Pause/cooldown timers | absent → scheduled → elapsed/cancelled | Controller `scheduleDebounce`, `scheduleCooldown`; task cancellation and current state gate effects |
| Accepted insertion chain | queued → validating → inserting → success/failure; failed epoch refuses remainder | Controller `commitSegment`, `failCommitChain`; ordered segments, ownership checked before and after suspension |
| Render authorization | candidate → focus-valid draw or hidden/rejected | Controller `canRenderGhost`; render epoch, ghost and exact focus authorize drawing |
| Stream delivery coalescing | empty → pending latest/scheduled → drained | `CotypeMacOS/StreamedCandidateCoalescer.swift`; lock, one delivery scheduled, newest value wins |
| Deferred draw/caret retry | queued show/hide → draw/retry → visible/hidden/exhausted | `CotypeMacOS/GhostTextRenderer.swift`; newer presentation invalidates old retries |
| Visibility and offered metric | generated → rendered → actually visible → counted once | `CotypeMacOS/CollectingRenderer.swift`, controller visibility callback; invisible candidates never take Tab |
| Insertion route | target validation → direct write or unsupported fallback → success/failure | `CotypeMacOS/InsertionRouter.swift`; ambiguous attempted writes never fall back and duplicate text |
| Clipboard transaction | snapshot → temporary write → target recheck → paste → conditional restore | `CotypeMacOS/PasteboardInserter.swift`; restore only while still owning clipboard change count |
| AX preparation | timeout configured; per-process asleep → awakened → invalidated on activation | `CotypeMacOS/AXWake.swift`; bounded read calls, web accessibility reasserted when needed |
| Terminal caret | accumulated typed suffix → derived geometry; edit/focus reset | `CotypeMacOS/TerminalCaret.swift`; geometry belongs to current typing context |

## App, settings and daemon machines

| Machine | States and transitions | Owner/source and invariant |
| --- | --- | --- |
| App lifecycle | boot → running → terminating/flush | `CotypeMenuApp/AppDelegate.swift`; registers preferences/input/UI, flushes storage on termination |
| Menu panel and selection | hidden ↔ visible; entries rebuilt → keyboard selection/action | `AppDelegate.swift`, `MenuBarPanelView.swift`, `MenuBarPanelController.swift`; model projects completion/status |
| Settings window | absent → open/key/resigned/minimized → closed | `AppDelegate.swift`; observers and input self-active state track window presence |
| App activation | accessory → activating regular → regular → accessory | `CotypeMenuApp/AppActivation.swift`; cancellable handoff, pure window-presence decision |
| Input plan | stopped ↔ observer/interaction/hotkey/click plan installed | `CotypeMenuApp/GlobalKeyMonitor.swift`; self-active, enabled and completion state determine plan |
| Keyboard event tap | stopped → starting → running → disabled → recovering/stopping → restart | `GlobalKeyMonitor.swift`, `KeyboardTapEngine`; lock owns thread/install/restart flags |
| Permission observation | initial snapshot → polling → changed snapshot | `CotypeMenuApp/SetupPane.swift`, `PermissionMonitor`; read-only OS grant truth |
| UI model monitor | idle → refreshing → updated/stopped | `CotypeMenuApp/ModelStatusViews.swift`, `LocalModelsMonitor`; generation rejects retired refresh results |
| Coalesced model read | idle → in-flight/shared → complete or retired | `CotypeMacOS/LocalModelsStatus.swift`, `LocalModelsStatusRefresher`; only current read can clear handle |
| Model readiness | unreachable / alias missing / cold / warm with invalid endpoint / ready | `LocalModelsStatus.swift`, `DaemonRoutedEngine.swift`; registry snapshot and loopback validation authorize routing |
| Completion engine | status → resolve → warm-request/fail or keepalive → stream → end/error/cancel | `CotypeMacOS/DaemonRoutedEngine.swift`; daemon owns model loading, editor text remains on loopback |
| Model warming | unrequested / retry-throttled / keepalive-throttled / in-flight / finished | `DaemonRoutedEngine.swift`, `LocalModelsWarmer`; per-model dictionaries gate requests |
| Practice field | empty/unavailable → debouncing → streaming → candidate/success/error; stepped remainder | `SetupPane.swift`, `PracticeField`; own task and draft, separate from editor completion |
| Setup checklist | permission/model/practice facts → incomplete/complete | `SetupPane.swift`; practice achievement is sticky only within the session |
| Launch at Login | OS not-registered/enabled/requires-approval/not-found; registration operation may fail | `CotypeMenuApp/GeneralPane.swift`, `LaunchAtLoginModel`; real SMAppService state is truth |
| Shortcut recorder | idle → recording → captured/cancelled | `CotypeMenuApp/ShortcutsPane.swift`; recording owns local event monitor |
| Settings selection/reset | selected section → reset action registered/unregistered | `CotypeMenuApp/SettingsView.swift`; section change clears reset action |
| App/site rule editing | inherited/absent → draft/invalid → saved enabled/disabled/instructions → removed | `CotypeMenuApp/AppSettingsPane.swift`; effective policy derives from stores, not unsaved drafts |
| Privacy actions | export → save/cancel/write result; deletion → confirmation/cancel/delete result | `CotypeMenuApp/PrivacyDataPane.swift`; confirmation precedes destructive storage work |
| Sparkle lifecycle | inert or configured → privacy defaults → auto-check preference → started → check | `CotypeMenuApp/SparkleUpdateController.swift`; startup order follows explicit core policy |
| About assessment | unknown → checking → notarization/signature result | `CotypeMenuApp/AboutPane.swift`; asynchronous read-only assessment |

## Core, storage and delivery machines

| Machine | States and transitions | Owner/source and invariant |
| --- | --- | --- |
| Pipeline run | requested → context → abstain or prompt → stream → fixed/end → candidate/empty | `CotypeCore/Pipeline.swift`; cancellation/failure clears rendering during generation |
| Provider stream | opening → tokens → end/finish/error/cancel | `CotypeCore/Stage.swift`, `Providers/InferenceEngines.swift`; `.end` is terminal; termination cancels provider work |
| Continuation healing | waiting prefix → partial match → stripped/passthrough | `CotypeCore/CompletionTypes.swift`; mismatch releases accumulated characters |
| Sanitizer settlement | mutable partial output → settled output → safe early stop | `CotypeCore/Providers/OutputSanitizer.swift`; partial controls/echoes delay settlement |
| Output length/boundaries | accumulating → sentence/word cap/emoji boundary → fixed candidate | `Pipeline.swift`, `SuggestionWordLimiter.swift`, `CaretBoundary.swift`; bounded user-selected suggestion |
| Writing extraction | unfinished sentence → punctuation → whitespace/newline commit | `CotypeCore/WritingMemory.swift`; incomplete trailing words withheld |
| Privacy eligibility | unreadable/untrusted/sensitive → blocked; readable permitted → allowed | `CotypeCore/SensitiveContext.swift`; rejects protected contexts before inference |
| Personalization persistence | clean → dirty → scheduled → writing → clean/rearmed or failed | `CotypeCore/PersonalizationStore.swift`; serialized storage with surfaced write health |
| Personalization deletion | flush prior writes → clear → enqueue empty → flush → verify | `PersonalizationStore.swift`; concurrent later records survive according to existing semantics |
| Storage migration/retention | absent/old array/JSONL → decode → prune → secured/flush | `PersonalizationStore.swift`; current retained representation persists |
| Not-shown persistence | clean → dirty/debounced → snapshot write → clean; reset serialized | `CotypeCore/NotShownStore.swift`; aggregate counts only, no editor text |
| Policy persistence | inherited → explicit override → effective merge; remove → inheritance | `CotypeCore/AppOverridesStore.swift`, `WebsiteRules.swift`; website identity must be trusted |
| Power eligibility | automatic enabled ↔ battery/low-power pause | `CotypeCore/PowerPolicy.swift`; manual trigger remains exempt |
| Updater policy | unconfigured → inert; configured → ordered defaults/preferences/start | `CotypeCore/SparkleUpdatePolicy.swift`; privacy settings applied before startup |
| Notarization subprocess | pending → accepted/rejected/signature classification | `CotypeCore/NotarizationChecker.swift`; assessment is read-only |
| Release eligibility | decode → validate → verify signature → monotonic version allowed/rejected | `CotypeUpdateCore/UpdateManifest.swift`, `CotypeUpdate/main.swift`; signed release and version gates |
| Evaluation | pending case → result/error → scored suggestion/abstention/failure → aggregate gate | `CotypeEval/EvalRunner.swift`, `Eval.swift`; deterministic fixtures, explicit live lane |
| Build/release | build → stamp/embed → sign inside-out → verify → notarize/staple → package → publish | `scripts/build-app.sh`, `notarize.sh`, `package-release.sh`, `publish-update.sh`; release stages preserve signing contract |
| Installation | stage/verify → stop/back up old → swap/verify → discard backup → relaunch | `scripts/install.sh`; expected swap/verification failures restore backup |
| Verification lane | deterministic gates → optional warm-model eval → pass/fail/skip | `scripts/verify.sh`; deterministic gate does not require personal editor content |

## Remaining findings and behavior choices

These are source-review findings, not claims of reproduced runtime failures. They
were left outside the three regression-backed corrections above.

- **Completion terminal-state drift:** controller privacy/failure paths settle
  interaction but leave `CompletionFlow` generating; cancellation settles flow
  and published phase without settling interaction. Consolidate terminal
  transitions with controller-level cancellation/privacy/error regressions.
- **Readiness disagreement:** UI often treats warmth as readiness; engine also
  requires reachability, registration and a safe loopback endpoint. Derive a
  shared readiness projection before changing user-facing labels/actions.
- **Practice request identity:** text equality admits an ABA edit (A → B → A).
  Use request identity and cancellation checks for all final/error updates.
- **Login error visibility:** `LaunchAtLoginModel.setEnabled` catches an error,
  then `refresh()` replaces its status message. Separate OS status from the
  most recent operation outcome.
- **Permission observer lifetime:** repeating timer lacks teardown and the
  notification token is discarded. Tie both to the observer lifetime.
- **Pipeline diagnostics:** context/prompt errors precede the generation catch
  and may leave prior outcome/timing metadata. Reset per-request diagnostics at
  entry and test failures at each stage.
- **Not-shown write failure:** dirty state is cleared before a swallowed writer
  error. Add an explicit failed/retry state without creating an endless retry.
- **About subprocess lifetime:** notarization subprocess has no timeout. Bound
  execution and define a user-visible timeout outcome.
- **Install interruption:** EXIT cleanup removes the rollback backup even on an
  unexpected exit after moving the old bundle. Preserve or restore it on that
  path before making install interruptions part of this change.
- **Pointer during debounce:** pointer movement does not arm a timer but leaves
  an existing debounce armed. This can generate in the newly focused context;
  decide the intended behavior explicitly before changing it.
- **Render/commit coupling:** `commitsInFlight` is global, so a previous epoch's
  outstanding insert can delay a new ghost. This is conservative behavior;
  revisit only with focused rendering and insertion-order tests.

## Validation scope

The insertion regressions cover full and stepped acceptance, each with suspended
success and failure, and prove a new candidate still accepts into its own field.
The status regression deterministically retires A, starts B, finishes A, then
proves B remains cancellable before a subsequent read. Pipeline regressions
exercise extra tokens and errors after `.end`.

No live editor text or model output was collected. Existing tests and these new
regressions use synthetic data. Installed-app UX remains a separate verification
step; this source audit does not establish live Accessibility or event-tap health.

Verification on 2026-11-09:

- `make build`: passed with warnings treated as errors.
- `make test`: 854 tests, four skipped, zero failures; E2E 22/22.
- Strict design lint on all seven touched Swift files: zero hits.
- Independent review of the production diffs and this report: no blocking issues.
- `swift test --sanitize=thread`: compilation passed, test process crashed with
  signal 11 before tests. A separate empty Swift program compiled with
  `swiftc -sanitize=thread` also crashed with SIGSEGV (exit 139). Sanitizer
  verification is unavailable on this host; it is not a passing check.
- `./scripts/verify.sh`: debug/release builds, tests, bundle plist/rpath/codesign
  checks passed. Live model lane was not requested. Gatekeeper rejected the
  local development bundle; the deterministic gate reports that separately
  and still passes. This is not a notarized release.
- No installation or app launch was performed. Live editor behavior remains
  unverified, in keeping with the rule against opening apps without a request.
