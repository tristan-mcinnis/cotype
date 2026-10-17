# Cotype — Project Contract

Canonical file. `AGENTS.md` is a symlink to this file so every runtime reads one contract.

## Product

Cotype is a private, personal macOS menu-bar app for local AI text completion.
It reads the focused text field through Accessibility (plus bounded visible
window text when the user turns that on), asks the local model for the next
few words (the Suggestion length setting: 1-3, 3-6, or the rest of the
sentence up to 16), shows them as ghost text, and inserts them only when
accepted. The local-models daemon owns the registry, weights, and load/unload
lifecycle; the Local Models menu bar is its face. Cotype keeps no second model
in memory unless the legacy in-process fallback is installed on purpose.

The product name is always **Cotype** in user-facing copy. Technical identifiers:

- Swift package: `Cotype`; libraries `CotypeCore`, `CotypeUpdateCore`, `CotypeEval`, `CotypeMacOS`
- Executables: `cotype`, `cotype-menu`, `cotype-eval`, `cotype-diagnostics`, `cotype-update`
- Installed app: `~/Applications/Cotype.app` (built by `scripts/install.sh`)

## Rules

- Look: `../design-system/DESIGN.md`. The tokens (`HouseDesign`) and the shared
  menu-bar kit (`HouseUIKit`) come from the design-system package, pinned in
  `Package.swift` by GitHub URL and tag. There are no copies here: to change
  the look, change design-system, tag it, and raise the pin. The menu app's own
  panel code stays in `MenuBarPanelView.swift` and `MenuBarPanelController.swift`.
- Code: `../design-system/SWIFT.md`. This repo's floor is **macOS 14, swift-tools
  5.10, XCTest**. Hold the floor; migrate to 6.2 and Swift Testing as one change,
  not file by file.
- Local debt to burn down, not add to: `@unchecked Sendable` without a guard
  comment, `DispatchQueue` in new code.

## Private data and secrets

Never commit API keys, personal text captured from screens or fields, model
weights, or local settings. Cotype reads other apps' text; nothing it reads may
land in fixtures, logs, screenshots, or tests. Sparkle signing keys stay outside
the repo (see `docs/RELEASE.md`).

## Boundaries

Preserve: ghost text inserted only on accept; Accessibility read paths that
never write except the accepted insertion; the Local Models daemon as the
default engine; Launch at Login as a real registration; no telemetry.

## Development

- `swift build` and `swift test` from the repository root.
- `./scripts/build-app.sh` builds, signs, and version-stamps `dist/Cotype.app`.
- `./scripts/install.sh` installs and relaunches; `./scripts/verify.sh` is the
  deterministic gate (`--model-lane` when a model must be present).
- `./scripts/diagnostics.sh` prints a safe version, model, and permissions report.
- Release: `docs/RELEASE.md` (Sparkle appcast, notarization).

## Verification

Run `swift test` after source changes. For a change the installed app must
show, run `./scripts/install.sh`, open Cotype, and see the change before
reporting done. `../design-system/bin/design-lint --strict` on touched files.
