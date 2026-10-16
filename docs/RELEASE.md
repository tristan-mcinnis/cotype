# Cotype Release Documentation

This documents how to produce a **personal** (this Mac) build and how to reach a
**distribution-ready** build. The scripts here favor the personal path by
default and treat Developer ID signing + notarization as an explicit, opt-in
step that never runs unless the credentials are actually present on the machine.

## Status (current, personal build)

- **Default signing:** Apple Development (or ad-hoc when no certificate exists,
  e.g. CI). **Not notarized** and **not Developer ID-signed** unless you opt in.
- **Licensing: all rights reserved. No public license is granted** by this
  repository for Cotype itself in this personal-ready pass. Only third-party
  components carry their own licenses (llama.cpp is MIT; the Gemma model is released under Apache-2.0). See [`licenses.md`](licenses.md).
- **Gatekeeper** rejects the personal build (`spctl -a -vvv -t exec` -> rejected)
  because it is not notarized. This is expected and NOT a defect.
- **Apps it is installed to:** `~/Applications/Cotype.app`.
- The scripts deliberately **do not** bypass macOS TCC or grant permissions on
  your behalf. They only report preflight status and open System Settings.

## Prerequisites

- macOS 14+ (the app targets macOS 14, builds on the current macOS).
- Xcode Command Line Tools (`xcode-select --install`).
- Swift 5.10+ (SwiftPM tools version).
- A signing identity in the Keychain for personal builds (auto-detected), or
  `COTYPE_SIGN_IDENTITY` / `COTYPE_DEVELOPER_ID_APP` for release signing.

## Personal build & install

```bash
./scripts/build-app.sh          # builds dist/Cotype.app (signed, version-stamped)
./scripts/install.sh            # build, quit running Cotype, install, relaunch, verify
./scripts/install.sh reinstall  # robust idempotent reinstall
./scripts/install.sh uninstall  # remove the app (leaves settings/model intact)
./scripts/verify.sh             # deterministic tests; skips the model lane by default
./scripts/verify.sh --model-lane  # run the model eval lane (requires the model; fails if absent)
./scripts/diagnostics.sh        # version/model/hash/permissions report (no sensitive content)
```

`./scripts/install.sh`:
- Builds the app bundle.
- Installs Cotype as a thin client of the Local Models daemon. It does not copy
  the shared Gemma weights by default.
- **Quits any running Cotype** first (graceful, then SIGTERM/SIGKILL), replaces
  the bundle, and **relaunches** it.
- Verifies `codesign`, the `rpath`, and the `Info.plist` after install.
- Reports **preflight** permission status (Accessibility / Input Monitoring /
  event posting) read-only; it never grants or bypasses TCC.

The optional legacy standalone lane uses
`$HOME/Models/gguf/gemma-4-E2B-it-Q4_K_M.gguf` as its source. Pass
`--with-in-process-model` to install a private Cotype copy, or `--require-model`
to make that copy mandatory. Normal installs manage `gemma-it` through the
Local Models menu bar.

## Version stamping

- `VERSION` at the repo root is the marketing version → `CFBundleShortVersionString`.
- `CFBundleVersion` = git commit count (a stable-ish build number).
- Info.plist also carries `CotypeBuildMode`, `CotypeBuildGitCommit`,
  `CotypeBuildGitCommitLong`, `CotypeBuildDate`, `CotypeBundleID`,
  `CotypeLlamaBuild`, `CotypeLlamaVersion`, `CotypeLlamaLicense`,
  `CotypeModelLicense`, `CotypeModelLicenseURL`, `CotypeSigningIdentity`,
  `CotypeArchitecture` (always `arm64`), `CotypeNotarized` (always `false` at
  build time), `CotypeReleaseCandidate` (`true` only for a `--notarize` build),
  and — for a release-candidate build only — `SUFeedURL` and `SUPublicEDKey`.

`CotypeNotarized` is never `true` at build time. Notarized status is derived at
runtime from Gatekeeper (`NotarizationChecker`), so the About pane is truthful
for a personal build, a Developer ID release candidate, and a fully notarized
build alike.

## CI

`.github/workflows/ci.yml` runs hosted build/release jobs on arm64 `macos-15`
(the app deployment target remains macOS 14):

- **build-test** (every PR / push): debug + release build, full deterministic
  test suite, app-bundle build + validation, `verify.sh` (deterministic, model
  lane explicitly skipped), and a no-model diagnostics smoke run.
- **model-eval** (opt-in, `workflow_dispatch`, model-equipped runner): runs
  `verify.sh --model-lane`, which **fails** if the pinned model is absent rather
  than silently passing. This is the "required model vs explicit skip"
  distinction: the deterministic gate never needs a model; the eval lane always
  does.

## Opt-in Developer ID + Notarization release path

The following steps are **manual and opt-in**. Nothing runs them automatically.
They require a paid Apple Developer account plus a **Developer ID Application**
certificate and an App Store Connect / notarization credential.

### 1. Create / install the Developer ID Application identity

Install a **Developer ID Application** certificate in the Keychain (or export a
`.p12` and import it). Identify it:

```bash
security find-identity -v -p codesigning
```

### 2. Build, sign, enable Hardened Runtime, and record the release identity

```bash
COTYPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
COTYPE_BUILD_MODE=release \
./scripts/build-app.sh --notarize
```

`--notarize` (or `COTYPE_NOTARIZED=1`) requires a **Developer ID Application**
identity, forces Hardened Runtime, stamps `CotypeReleaseCandidate=true` in
Info.plist, and enforces that the built binary is **arm64** (Apple Silicon
only). It does **not** claim `CotypeNotarized=true` — the build output is a
Developer ID **release candidate**, not yet notarized. The About pane derives
notarized status at runtime from Gatekeeper, so a candidate is shown as "not
notarized" until notarization actually succeeds.

Without `--notarize`, the app is a personal (Apple Development / ad-hoc) build
and reports `CotypeReleaseCandidate=false`.

### 3. Notarize and staple

`scripts/notarize.sh` (see its `--help`) performs `xcrun notarytool submit`,
`xcrun stapler staple`, and then verifies with `codesign`, `spctl`, and
`stapler validate`. It requires `COTYPE_DEVELOPER_ID_APP` (the Developer ID
Application identity) and Apple notarization credentials (`NOTARYTOOL_*`
or the App Store Connect API key). It **fails loudly** and does not claim success
if the credentials are missing — the personal build path never calls it.

For security, the Apple ID app password is referenced as `--password @env:NOTARTOOL_PASSWORD`
in the `notarytool submit` command line, so the secret never appears in the
process argument list (argv). The API key is passed by file path (`--key`), whose
content `notarytool` reads from disk rather than argv. Ensure the `NOTARYTOOL_*`
variables are set in the environment when you run it.

### 4. Package a versioned artifact

```bash
./scripts/package-release.sh --sign-with <ed25519-private.key> --require-signature --channel-url https://updates.example.com/cotype
```

This creates a versioned `.zip`/`.dmg` with checksums and release notes in
`dist/release/`, enforces **release monotonicity** (the marketing version must
not downgrade and the build number must strictly advance relative to the
previous `update-manifest.json`), refuses to package a non-arm64 build, and then
invokes `scripts/update-manifest.sh` to emit a signed `update-manifest.json`.

### 5. Automatic updates via Sparkle 2

Cotype uses **Sparkle 2** (`https://github.com/sparkle-project/Sparkle`), the
standard macOS auto-update framework, pulled in via Swift Package Manager and
embedded + signed by the release build. Sparkle performs the whole update flow
(appcast fetch, Ed25519 (`SUPublicEDKey`) signature verification, artifact
SHA-256 verification, download, install, relaunch), so the app never downloads
or installs an update by hand.

**App side.** `SparkleUpdateController` wraps `SPUStandardUpdaterController`
(starting updater, automatic-check scheduling). The About & Updates pane exposes
**Check for Updates** (calls `checkForUpdates(_:)`) and an **Automatically check
for updates** toggle (persisted in UserDefaults and driven through
`updater.automaticallyChecksForUpdates`). The updater is only initialized when
the bundle is a release candidate that ships `SUFeedURL` + `SUPublicEDKey`; a
dev build has neither, so Sparkle stays inert (no network).

**Embedding/signing.** `scripts/build-app.sh` copies `Sparkle.framework` from
the SPM artifact into `Cotype.app/Contents/Frameworks`, and signs Sparkle's own
bundled helper (`Versions/Current/Updater.app`) and its XPC services
(`XPCServices/*.xpc`) first, then the framework, then the app, in the order
Sparkle requires. `Cotype-Menu` links `@rpath/Sparkle.framework`, which the
existing `@executable_path/../Frameworks` rpath resolves.

**Release-only config.** For an actual release candidate (`--notarize`) the
build writes `SUFeedURL` (= `<COTYPE_UPDATE_FEED_URL>/appcast.xml`) and
`SUPublicEDKey` (= base64 Ed25519 public key) into `Info.plist` with proper XML
escaping. A dev/personal build omits both.

**Producer (appcast).** `scripts/generate-appcast.sh` produces `appcast.xml`
using Sparkle's own `generate_appcast` tool, which implements the appcast EdDSA
signature algorithm (this script only discovers the pinned tool, stages a single
canonical archive so it does not fail on duplicate `CFBundleVersion` entries,
and, when a raw-seed key is supplied, fills in any missing enclosure signature
using Sparkle's own `sign_update` — it never re-implements signing). It is a
release-time step:

```bash
# Create the update signing keypair once. cotype-update writes base64 EdDSA keys
# (ed25519-private.key / ed25519-public.key); the private key file CONTAINS the
# 44-char base64 string (it is NOT a PEM file).
swift run cotype-update keygen --out ~/.cotype-update

# Emit a Sparkle appcast + signed archive for a release dir:
./scripts/generate-appcast.sh --release-dir dist/release \
  --private-key ~/.cotype-update/ed25519-private.key \
  --channel-url https://updates.example.com/cotype

# Prove the tooling runs the REAL pinned tool end-to-end:
./scripts/generate-appcast.sh --self-test
```

**Monotonicity contract.** `scripts/update-manifest.sh` and
`scripts/package-release.sh` also emit a signed `update-manifest.json` — this is
the release **contract** CI uses to enforce version/build monotonicity across
releases (via `COTYPE_PREVIOUS_MANIFEST`, the previously published manifest) and
guarantee absolute artifact URLs (`--channel-url`). It is not the app's update
feed (that is the Sparkle appcast).

**Publish (atomic).** `scripts/publish-update.sh` is the safe publish contract. It
stages exactly `appcast.xml` + the canonical ZIP (+ optional notes/manifest),
validates that every enclosure URL is absolute under the channel base and is
EdDSA-signed, prints an ordered plan, and refuses to touch the channel unless
`--publish --command <upload>` is given. Order is **archive first, appcast LAST**
(appcast is the live switch); a failed appcast upload leaves the previous feed
live. Old archives are retained (never auto-deleted); rollback is to re-publish
the previous appcast. CI only publishes on an explicit `publish` workflow input;
otherwise it emits a ready-to-publish artifact + dry-run plan and makes **no**
claim that the channel is live.

**Network disclosure:** when a release feed is configured, checking for updates
contacts the appcast URL. Cotype sets Sparkle to `sendsSystemProfile=false` and
`automaticallyDownloadsUpdates=false`, so it sends no system profile to the feed
and downloads an update only after the user approves it in Sparkle's UI. No
completion text, settings, model data, or telemetry are sent. `PRIVACY.md`
documents the same release-feed behavior for users.

`scripts/update-manifest.sh --self-test`, `scripts/verify.sh --self-test`, and
`scripts/generate-appcast.sh --self-test` run deterministic checks (semver/build
monotonicity with prerelease ordering, arm64 detection, manifest schema
round-trip, XML escaping, key format) with no build, model, or credentials.

### 6. Update / rollback / clean-machine testing

Before shipping, test install, update, rollback, and uninstall on a **clean,
non-developer Mac**. Because the bundle identity (`com.tristan.cotype`) is
stable, updates do not reset Accessibility / Input Monitoring grants, provided
you repackage the same bundle ID.

## What this automation does NOT do

- It does **not** grant, exercise, or bypass macOS TCC permissions. Install only
  reports preflight status and opens System Settings.
- It does **not** claim notarization or Developer ID signing for personal builds.
- It does **not** ship model weights. The model must be provided locally (or
  acquired in-app once the downloader is wired, see the production-readiness plan).
- It does **not** implement public-distribution readiness (P0 product blockers
  such as default-off feedback storage, output sanitization, shortcut handling,
  in-app model acquisition). See `docs/production-readiness-plan.md`.

## Release checklist (distribution)

Run from `docs/production-readiness-plan.md` §CI and §Release. In summary:

- [ ] P0 product blockers closed (sanitizer, defaults, shortcut, model download).
- [ ] Deterministic CI green.
- [ ] `verify.sh --model-lane` green against a pinned model hash running the **full seeded suite** (not a 3-case smoke).
- [ ] Developer ID + Hardened Runtime + notarization + staple verified; `CotypeNotarized=true` reported truthfully.
- [ ] Versioned artifact (zip/dmg) with checksum, release notes, and a **signed** `update-manifest.json`.
- [ ] Release monotonicity enforced (version never downgrades; build number strictly advances); artifact is arm64.
- [ ] Clean-machine install/update/rollback/uninstall tested.
- [ ] Privacy/network capture: no egress after model setup.
- [ ] Accessibility (VoiceOver, keyboard-only, Increase Contrast) checked.
