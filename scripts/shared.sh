#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared constants and helpers for Cotype's build / install / verify / release
# tooling. Source this from the other scripts; it is not meant to be executed
# directly.
#
#   source "$(dirname "$0")/shared.sh"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Version & bundle identity
# ---------------------------------------------------------------------------

# Basis marketing version lives in VERSION at the repo root. Env override
# wins; otherwise the VERSION file; otherwise a sensible fallback. Derived build
# metadata (commit, build number, date) is computed from git at packaging time.
COTYPE_VERSION_FILE="${COTYPE_VERSION_FILE:-$ROOT/VERSION}"
if [[ -n "${COTYPE_VERSION:-}" ]]; then
  COTYPE_VERSION="$COTYPE_VERSION"
elif [[ -f "$COTYPE_VERSION_FILE" ]]; then
  COTYPE_VERSION="$(tr -d '[:space:]' < "$COTYPE_VERSION_FILE")"
else
  COTYPE_VERSION="0.1.0"
fi

# Precedence: env override, then default. Every setting that a user or CI is
# likely to override (version, bundle id, model path, install dir, signing
# identity, model/lane flags) clears the rest, so shared.sh must never clobber
# an already-set value.
COTYPE_BUNDLE_ID="${COTYPE_BUNDLE_ID:-com.tristan.cotype}"
COTYPE_APP_NAME="${COTYPE_APP_NAME:-Cotype}"
COTYPE_PRODUCT="${COTYPE_PRODUCT:-cotype-menu}"
COTYPE_DISPLAY_NAME="${COTYPE_DISPLAY_NAME:-Cotype}"

# Per-build metadata (computed here so diagnostics, verify and release all agree).
COTYPE_GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
COTYPE_GIT_COMMIT_LONG="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
# "true" when tracked files differ from HEAD at build time, so an installed app
# can prove it is exactly the committed source (scripts/acceptance.sh T4).
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  COTYPE_GIT_DIRTY="true"
else
  COTYPE_GIT_DIRTY="false"
fi
COTYPE_BUILD_NUMBER="${COTYPE_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
COTYPE_BUILD_DATE="$(git -C "$ROOT" log -1 --format='%cd' --date=format:%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)"
COTYPE_BUILD_MODE="${COTYPE_BUILD_MODE:-development}"

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

COTYPE_MODEL_FILENAME="${COTYPE_MODEL_FILENAME:-gemma-4-E2B-it-Q4_K_M.gguf}"
COTYPE_MODEL_SHA256="${COTYPE_MODEL_SHA256:-740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8}"
# Legacy standalone fallback only. The normal Cotype path uses the Local Models
# daemon, whose registry owns this file under ~/Models/gguf.
COTYPE_MODEL_SOURCE="${COTYPE_MODEL_SOURCE:-$HOME/Models/gguf/$COTYPE_MODEL_FILENAME}"
COTYPE_MODEL_DIR="${COTYPE_MODEL_DIR:-$HOME/Library/Application Support/Cotype/Models}"
COTYPE_MODEL="${COTYPE_MODEL:-$COTYPE_MODEL_DIR/$COTYPE_MODEL_FILENAME}"
# Hugging Face repo for the model, if/when the in-app downloader is wired.
COTYPE_MODEL_REPO="${COTYPE_MODEL_REPO:-unsloth/gemma-4-E2B-it-GGUF}"
COTYPE_MODEL_REVISION="${COTYPE_MODEL_REVISION:-0314792d7f1f7e229411f620751375812bb9faf2}"
COTYPE_MODEL_LICENSE="${COTYPE_MODEL_LICENSE:-Apache-2.0}"
COTYPE_MODEL_LICENSE_URL="${COTYPE_MODEL_LICENSE_URL:-https://ai.google.dev/gemma/docs/gemma_4_license}"

# Rough disk / RAM guidance shown during install and in docs. Not authoritative.
COTYPE_MODEL_SIZE_HUMAN="${COTYPE_MODEL_SIZE_HUMAN:-~3.5 GB}"

# ---------------------------------------------------------------------------
# llama.cpp
# ---------------------------------------------------------------------------

# Pinned binary-target URL in Package.swift, e.g. llama-b10665-xcframework.zip.
COTYPE_PACKAGE_URL="$(\
  grep -m1 -Eo 'llama-b[0-9]+-xcframework\.zip' "$ROOT/Package.swift" 2>/dev/null \
  || echo llama-b10665-xcframework.zip)"
COTYPE_LLAMA_BUILD="${COTYPE_LLAMA_BUILD:-${COTYPE_PACKAGE_URL#llama-}}"
COTYPE_LLAMA_BUILD="${COTYPE_LLAMA_BUILD%%-xcframework.zip}"   # e.g. b10665
COTYPE_LLAMA_VERSION="${COTYPE_LLAMA_VERSION:-${COTYPE_LLAMA_BUILD#b}}"
COTYPE_LLAMA_LICENSE="${COTYPE_LLAMA_LICENSE:-MIT}"

# ---------------------------------------------------------------------------
# Install / app destinations
# ---------------------------------------------------------------------------

COTYPE_INSTALL_DIR="${COTYPE_INSTALL_DIR:-$HOME/Applications}"
COTYPE_APP="${COTYPE_APP:-$COTYPE_INSTALL_DIR/$COTYPE_APP_NAME.app}"
COTYPE_DIST="${COTYPE_DIST:-$ROOT/dist}"
COTYPE_DIST_APP="${COTYPE_DIST_APP:-$COTYPE_DIST/$COTYPE_APP_NAME.app}"

# Build-local state (gitignored via .build/) used to persist the signing
# identity so successive rebuilds/installs reuse a stable identity.
COTYPE_STATE_DIR="$ROOT/.build/cotype-state"
COTYPE_SIGN_STATE_FILE="$COTYPE_STATE_DIR/signing-identity"

# ---------------------------------------------------------------------------
# Strict notarization assessment (mirrors CotypeCore.NotarizationChecker)
# ---------------------------------------------------------------------------

# True only when the bundle is BOTH accepted by Gatekeeper with the VERBOSE source
# 'Notarized Developer ID' AND codesigned with a Developer ID Application identity.
# A mere `spctl` exit-0 (e.g. a locally-trusted Apple Development build) is not
# treated as notarized.
is_notarized_strict() {
  local bundle="$1" spout src dv
  [[ -d "$bundle" ]] || return 1
  spout="$(spctl -a -vvv -t exec "$bundle" 2>&1 || true)"
  src="$(printf '%s' "$spout" | awk '/^source=/{ print substr($0, 8); exit }')"
  [[ "$src" == "Notarized Developer ID" ]] || return 1
  dv="$(codesign -dv "$bundle" 2>&1 || true)"
  printf '%s' "$dv" | grep -q '^Authority=Developer ID Application' || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Architecture / Apple-Silicon enforcement
# ---------------------------------------------------------------------------

# Fail loudly unless the build HOST is arm64. Packaging is Apple-Silicon-only; we
# assert uname -m directly instead of trusting the runner label (which can drift,
# e.g. a macos-14 image moving to a non-arm64 host), so a wrong-arch runner fails
# with a clear message rather than producing a broken release.
require_apple_silicon_host() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "arm64" ]]; then
    die "Cotype targets Apple Silicon (arm64) only, but this host is '$arch'. Refusing to build/package a non-arm64 release."
  fi
}

# True when a Mach-O binary at $1 is arm64. Cotype targets Apple Silicon only; a
# release that bundles a non-arm64 (or universal-but-not-arm64) binary is a
# defect and must fail loudly rather than ship a broken menu-bar app.
is_arm64_binary() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  if has_command lipo && lipo -info "$path" >/dev/null 2>&1; then
    lipo -info "$path" 2>/dev/null | grep -q 'arm64'
  elif has_command file; then
    file "$path" | grep -q 'arm64'
  else
    return 1
  fi
}

# Die unless the binary is a validated arm64 Apple-Silicon binary.
require_arm64() {
  local path="$1"
  if ! is_arm64_binary "$path"; then
    die "$path is not an arm64 Apple-Silicon binary. Cotype targets arm64 only; refusing to package a release from a non-arm64 build."
  fi
}

# ---------------------------------------------------------------------------
# Release monotonicity helpers (pure shell, used by packaging/verify/release)
# ---------------------------------------------------------------------------

# True when $1 is a bare positive integer (no sign, no leading zeros beyond 0).
is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# True when the second arg is strictly greater than the first (integers).
num_gt() { local a="$1" b="$2"; is_positive_int "$a" || return 1; is_positive_int "$b" || return 1; (( b > a )); }

# True when $1 is a plausible semver MAJOR.MINOR.PATCH (optionally -pre/+build).
is_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

# semver_gt <a> <b>: true when version a is strictly NEWER than b, per SemVer
# 2.0.0 precedence (including prerelease ordering). Deployed as a pure-shell
# implementation so the release gates need no Swift toolchain at runtime. The
# tested `cotype-update compare` subcommand and `ReleaseVersionOrdering` (Swift)
# implement the same rules for the app/CLI.
semver_gt() {
  local a="$1" b="$2"
  is_semver "$a" || return 2
  is_semver "$b" || return 2
  awk -v a="$a" -v b="$b" '
    function stripbuild(s,   i) { i = index(s, "+"); if (i > 0) s = substr(s, 1, i - 1); return s }
    function splitcore(s,   i) { i = index(s, "-"); if (i > 0) return substr(s, 1, i - 1); return s }
    function splitpre(s,   i) { i = index(s, "-"); if (i > 0) return substr(s, i + 1); return "" }
    function idcmp(x, y) {
      if (x ~ /^[0-9]+$/ && y ~ /^[0-9]+$/) return (x + 0 > y + 0) ? 1 : ((x + 0 < y + 0) ? -1 : 0)
      if (x ~ /^[0-9]+$/) return -1
      if (y ~ /^[0-9]+$/) return 1
      if (x > y) return 1; if (x < y) return -1; return 0
    }
    function precmp(pa, pb,   x, y, n, m, i, c) {
      n = split(pa, x, "."); m = split(pb, y, ".")
      for (i = 1; i <= n || i <= m; i++) {
        if (i <= n && i <= m) { c = idcmp(x[i], y[i]); if (c != 0) return c }
        else if (i <= n) return 1
        else return -1
      }
      return 0
    }
    function corecmp(ca, cb,   x, y, i) {
      split(ca, x, "."); split(cb, y, ".")
      for (i = 1; i <= 3; i++) { if (x[i] + 0 != y[i] + 0) return (x[i] + 0 > y[i] + 0) ? 1 : -1 }
      return 0
    }
    BEGIN {
      a = stripbuild(a); b = stripbuild(b)
      ac = splitcore(a); bc = splitcore(b)
      ap = splitpre(a); bp = splitpre(b)
      c = corecmp(ac, bc)
      if (c != 0) exit (c > 0) ? 0 : 1
      if (ap == "" && bp == "") exit 1
      if (ap == "") exit 0
      if (bp == "") exit 1
      c = precmp(ap, bp)
      exit (c > 0) ? 0 : ((c < 0) ? 1 : 1)
    }
  '
}

# Assert that a new release is monotonic over the previous one.
#   release_is_monotonic <new_version> <new_build> <prev_version> <prev_build>
# Fails when the version downgrades, or when the build number does not advance.
release_is_monotonic() {
  local nv="$1" nb="$2" pv="$3" pb="$4"
  is_semver "$nv" || die "Release version '$nv' is not a valid semver MAJOR.MINOR.PATCH."
  is_positive_int "$nb" || die "Release build number '$nb' is not a positive integer."
  if [[ -n "$pv" ]] && is_semver "$pv"; then
    if semver_gt "$pv" "$nv"; then
      die "Release downgrades version: $nv is older than the previous $pv. Refusing monotonic release."
    fi
  fi
  if [[ -n "$pb" ]] && is_positive_int "$pb"; then
    # Die when the new build does NOT strictly advance over the previous.
    if ! num_gt "$pb" "$nb"; then
      die "Release build number $nb does not advance over previous $pb. Refusing non-monotonic release."
    fi
  fi
}

# ---------------------------------------------------------------------------
# cotype-update CLI (update-manifest signing / validation)
# ---------------------------------------------------------------------------

# Locate the built cotype-update binary, building it once per shell session
# (swift build is incremental, so an up-to-date build is cheap). Building every
# session means a stale binary (e.g. after a source change) is never used.
cotype_update_tool() {
  local bin="$ROOT/.build/release/cotype-update"
  if [[ "${COTYPE_UPDATE_BUILT:-0}" != "1" ]]; then
    # To stderr: this function's stdout is captured by `$(cotype_update_tool)`
    # in callers, so a status line here must never pollute the returned path.
    printf '\033[1;34m[cotype]\033[0m Building cotype-update tool…\n' >&2
    swift build -c release --product cotype-update >/dev/null
    COTYPE_UPDATE_BUILT=1
  fi
  printf '%s' "$bin"
}

# ---------------------------------------------------------------------------
# Logging / errors
# ---------------------------------------------------------------------------

log()   { printf '\033[1;34m[cotype]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[cotype]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[cotype:error]\033[0m %s\n' "$*" >&2; exit 1; }

has_command() { command -v "$1" >/dev/null 2>&1; }

is_ci() { [[ "${COTYPE_CI:-}" == "1" ]]; }
# Emit a log line. With a single argument it is a plain message; with two
# arguments the first is a CI group action (group / endgroup) and the second is
# the message.
ci_log() {
  if is_ci; then
    if [[ $# -ge 2 ]]; then printf '::%s::%s\n' "$1" "$2"; else printf '::group::%s\n' "$1"; fi
  else
    if [[ $# -ge 2 ]]; then log "$2"; else log "$1"; fi
  fi
}

# ---------------------------------------------------------------------------
# Code-signing identity
# ---------------------------------------------------------------------------

# Resolve the codesigning identity to use, in precedence order:
#   1. COTYPE_SIGN_IDENTITY override (validated against installed identities).
#   2. The last identity persisted by a previous build (stable across rebuilds).
#   3. An Apple Development identity (default for personal builds).
#   4. Ad-hoc signing ("-"), which works with no certificate (e.g. CI).
# Developer ID is release-only and must be selected explicitly through
# COTYPE_SIGN_IDENTITY. This avoids silently changing the app's designated
# requirement and losing existing TCC grants on a personal reinstall.
# The chosen identity is NOT assumed to be notarized; that is a separate opt-in
# step (see scripts/notarize.sh and docs/RELEASE.md).
resolve_sign_identity() {
  local identities ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  if [[ -n "${COTYPE_SIGN_IDENTITY:-}" ]]; then
    if [[ "$COTYPE_SIGN_IDENTITY" == "-" ]]; then echo "-"; return; fi
    if [[ "$ids" == *"$COTYPE_SIGN_IDENTITY"* ]]; then
      echo "$COTYPE_SIGN_IDENTITY"; return
    fi
    warn "COTYPE_SIGN_IDENTITY '$COTYPE_SIGN_IDENTITY' is not an installed codesigning identity; re-resolving."
  fi

  # Reuse the previously chosen *named* identity only if it is still installed.
  # Ad-hoc ("-") is never persisted as a stable identity: a cert-less CI build
  # must not lock a personal machine into ad-hoc once a certificate is present.
  if [[ -f "$COTYPE_SIGN_STATE_FILE" ]]; then
    local last
    last="$(cat "$COTYPE_SIGN_STATE_FILE")"
    if [[ -n "$last" && "$last" != "-" && "$ids" == *"$last"* ]]; then echo "$last"; return; fi
  fi

  local apple=""
  apple="$(printf '%s\n' "$ids" | awk -F'"' '/Apple Development/ { print $2; exit }')"
  if [[ -n "$apple" ]]; then echo "$apple"; return; fi

  echo "-"
}

# Persist the signing identity used by the most recent build. Ad-hoc ("-") is
# not persisted so it never pre-empts a real certificate on a later build.
record_sign_identity() {
  local identity="$1"
  [[ "$identity" == "-" ]] && return
  mkdir -p "$COTYPE_STATE_DIR"
  printf '%s' "$identity" > "$COTYPE_SIGN_STATE_FILE"
}

# Human-readable label for a codesigning identity (or "ad-hoc" for "-").
sign_identity_label() {
  local identity="$1"
  [[ "$identity" == "-" ]] && { echo "ad-hoc"; return; }
  # resolve_sign_identity already returns the display name; a fingerprint is
  # rare (only via COTYPE_SIGN_IDENTITY). If it looks like a name, echo it.
  if [[ "$identity" == *":"* ]]; then echo "$identity"; return; fi
  local ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  printf '%s\n' "$ids" | awk -F'"' -v want="$identity" 'index($0, want) { print $2; exit }' || echo "$identity"
}

# ---------------------------------------------------------------------------
# llama.cpp framework location
# ---------------------------------------------------------------------------

# Locate the extracted llama.xcframework that SPM pulled for the current build.
find_llama_framework() {
  local found
  found="$(find "$ROOT/.build" -type d -path '*llama.xcframework/macos-arm64_x86_64/llama.framework' 2>/dev/null | head -1 || true)"
  [[ -n "$found" ]] || die "Could not locate llama.framework under .build. Run \`swift build -c release\` first."
  printf '%s' "$found"
}

# ---------------------------------------------------------------------------
# Sparkle 2 framework location
# ---------------------------------------------------------------------------

# Locate the Sparkle.framework that SPM pulled for the current build (a binary
# target artifact under .build/artifacts/sparkle/…).
find_sparkle_framework() {
  local found
  found="$(find "$ROOT/.build" -type d -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' 2>/dev/null | head -1 || true)"
  [[ -n "$found" ]] || die "Could not locate Sparkle.framework under .build. Run \`swift build\` first."
  printf '%s' "$found"
}

# ---------------------------------------------------------------------------
# Plist/XML value escaping
# ---------------------------------------------------------------------------

# Escape a string for safe inclusion in an XML/plist <string> element, so a feed
# URL containing '&' or a key containing other special chars cannot break the
# Info.plist.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------

# Ask Cotype to quit, then wait, escalating to SIGTERM/SIGKILL only if it does
# not exit. Never kills other apps and never matches by bare process name (which
# could hit an unrelated Cotype running from a different bundle). Returns once
# Cotype is not running.
quit_cotype() {
  local app_bundle="$1" pid wait_ms
  # Match any process whose open command line references this specific bundle
  # path. This is robust to a same-path replacement (the running process keeps
  # the path string) and never matches a Cotype from another location.
  pid="$(pgrep -f "$app_bundle" 2>/dev/null | head -1 || true)"
  [[ -z "$pid" ]] && { log "Cotype is not running from $app_bundle."; return 0; }

  log "Quitting Cotype (pid $pid)…"
  # Graceful quit via AppleScript first (respects the app's own teardown).
  if has_command osascript; then
    osascript -e 'tell application id "com.tristan.cotype" to quit' >/dev/null 2>&1 || true
  fi
  for wait_ms in 1 2 3 4 5; do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then log "Cotype quit cleanly."; return 0; fi
  done
  warn "Cotype did not quit after 5s; sending SIGTERM."
  kill -TERM "$pid" 2>/dev/null || true
  for wait_ms in 1 2 3; do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then log "Cotype stopped."; return 0; fi
  done
  warn "Cotype still running; sending SIGKILL."
  kill -KILL "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    die "Unable to stop Cotype (pid $pid). Close it manually and retry."
  fi
  log "Cotype stopped."
}

# ---------------------------------------------------------------------------
# Bundle verification helpers
# ---------------------------------------------------------------------------

# Structural + signing verification of an app bundle. Returns non-zero on hard
# failures (missing binary, broken signature, missing rpath, invalid plist).
# Gatekeeper (spctl) assessment is informational only, because a personal build
# is Apple Development / ad-hoc signed and not notarized — that is expected, and
# must not be treated as a build failure.
verify_bundle() {
  local app_bundle="$1"
  local binary="$app_bundle/Contents/MacOS/$COTYPE_APP_NAME"
  local rpath_found plist_ok sig_ok=0 spctl_note=""

  if [[ ! -d "$app_bundle" ]]; then warn "App bundle missing: $app_bundle"; return 1; fi
  if [[ ! -f "$binary" ]]; then warn "App executable missing: $binary"; return 1; fi

  # 1. Info.plist lint.
  if plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null 2>&1; then
    plist_ok=0
  else
    plist_ok=1
  fi

  # 2. rpath to @executable_path/../Frameworks must be present.
  if otool -l "$binary" 2>/dev/null | grep -q '@executable_path/../Frameworks'; then
    rpath_found=0
  else
    rpath_found=1
  fi

  # 3. Signature structure. Ad-hoc ("-") and Developer ID both validate fine with
  # codesign --verify; a missing/invalid signature is a real defect.
  if codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1; then
    sig_ok=0
  else
    sig_ok=1
  fi

  # 4. Gatekeeper assessment — informational only for non-notarized builds.
  if has_command spctl; then
    spctl_note="$(spctl -a -vvv -t exec "$app_bundle" 2>&1 || true)"
  fi

  log "Bundle verification:"
  log "  plist   : $([[ $plist_ok -eq 0 ]] && echo ok || echo INVALID)"
  log "  rpath   : $([[ $rpath_found -eq 0 ]] && echo ok || echo MISSING)"
  log "  codesign: $([[ $sig_ok -eq 0 ]] && echo ok || echo INVALID)"
  if [[ -n "$spctl_note" ]]; then
    log "  gatekeep: $(printf '%s' "$spctl_note" | sed -n 's/^.*: /... /p' | head -1)"
  fi

  if [[ $plist_ok -ne 0 || $rpath_found -ne 0 || $sig_ok -ne 0 ]]; then
    warn "App bundle verification failed."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Model helpers
# ---------------------------------------------------------------------------

model_exists() { [[ -f "${1:-$COTYPE_MODEL}" ]]; }

model_sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

model_is_valid() {
  model_exists "$1" || return 1
  local actual expected="${2:-$COTYPE_MODEL_SHA256}"
  actual="$(model_sha256 "$1")"
  [[ -n "$actual" && "$actual" == "$expected" ]]
}
