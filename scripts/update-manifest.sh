#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Build a versioned, checksummed update manifest for the release channel and
# (optionally) sign it with the channel's Ed25519 key.
#
# This is the CLI contract for the update channel. A release is only "safe" to
# publish once `update-manifest.json` exists in the release directory, carries a
# checksum for every artifact, and is signed by the channel key (for a public
# channel). `cotype-update` is the signing/validation implementation; this
# script owns the file discovery and monotonicity checks.
#
#   ./scripts/update-manifest.sh [release-dir]
#       Build an UNSIGNED manifest for the release dir (warns; personal channel).
#
#   ./scripts/update-manifest.sh --sign-with <private.key> [release-dir]
#       Build and SIGN the manifest with an Ed25519 private key (public channel).
#
#   ./scripts/update-manifest.sh --require-signature --sign-with <key> [release-dir]
#       The production gate: refuse to emit an unsigned manifest.
#
# Options:
#   --version <v>          Marketing version (default: $COTYPE_VERSION)
#   --build <n>            Build number (default: $COTYPE_BUILD_NUMBER)
#   --commit <c>           Git commit (default: $COTYPE_GIT_COMMIT)
#   --mode <m>             Build mode (default: $COTYPE_BUILD_MODE)
#   --min-os <v>           Minimum supported macOS (default: 14.0)
#   --app-id <id>          Bundle identifier (default: $COTYPE_BUNDLE_ID)
#   --product <p>          Product name (default: $COTYPE_PRODUCT)
#   --channel-url <u>      Base URL prepended to artifact filenames (default: relative)
#   --sign-with <key>      Ed25519 private key file to sign the manifest
#   --require-signature    Refuse to emit an unsigned manifest (production)
#   --no-signature         Emit an unsigned manifest (personal channel, warns)
#   --self-test            Run deterministic checks and exit
#   --help                 Show this help
#
# Exit codes:
#   0 success
#   1 hard failure (non-monotonic, no artifacts, bad args, missing signing key)
#   2 usage error

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

SELF_TEST=0
SIGN_WITH=""
REQUIRE_SIGNATURE=0
NO_SIGNATURE=0
CHANNEL_URL=""
MIN_OS="${COTYPE_MIN_OS:-14.0}"

usage() {
  sed -n '2,28p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --sign-with) SIGN_WITH="$2"; shift 2 ;;
    --require-signature) REQUIRE_SIGNATURE=1; shift ;;
    --no-signature) NO_SIGNATURE=1; shift ;;
    --channel-url) CHANNEL_URL="$2"; shift 2 ;;
    --previous-manifest) PREVIOUS_MANIFEST_FILE="$2"; shift 2 ;;
    --version) COTYPE_VERSION="$2"; shift 2 ;;
    --build) COTYPE_BUILD_NUMBER="$2"; shift 2 ;;
    --commit) COTYPE_GIT_COMMIT="$2"; shift 2 ;;
    --mode) COTYPE_BUILD_MODE="$2"; shift 2 ;;
    --min-os) MIN_OS="$2"; shift 2 ;;
    --app-id) COTYPE_BUNDLE_ID="$2"; shift 2 ;;
    --product) COTYPE_PRODUCT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) RELEASE_DIR="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Self-test (deterministic; no release dir or key required)
# ---------------------------------------------------------------------------
self_test() {
  local failures=0
  check() { if "$@"; then :; else echo "  FAIL: $*"; failures=$((failures + 1)); fi; }

  echo "update-manifest self-test"
  check is_positive_int 1
  check is_positive_int 120
  ! is_positive_int 0 && : || { echo "  FAIL: is_positive_int accepted 0"; failures=$((failures + 1)); }
  ! is_positive_int -5 && : || { echo "  FAIL: is_positive_int accepted -5"; failures=$((failures + 1)); }
  ! is_positive_int 12a && : || { echo "  FAIL: is_positive_int accepted 12a"; failures=$((failures + 1)); }

  check is_semver 0.1.1
  check is_semver 1.0.0-rc.1
  ! is_semver 0.1 && : || { echo "  FAIL: is_semver accepted 0.1"; failures=$((failures + 1)); }
  ! is_semver not.a.version && : || { echo "  FAIL: is_semver accepted garbage"; failures=$((failures + 1)); }

  check semver_gt 0.1.1 0.1.0
  ! semver_gt 0.1.0 0.1.1 && : || { echo "  FAIL: semver_gt accepted a downgrade"; failures=$((failures + 1)); }
  ! semver_gt 0.1.0 0.1.0 && : || { echo "  FAIL: semver_gt accepted equal versions"; failures=$((failures + 1)); }
  # SemVer prerelease precedence: a release sorts after any prerelease of the same
  # core version, and prereleases order numerically / lexically per SemVer 2.0.0.
  check semver_gt 1.0.0 1.0.0-rc.1
  ! semver_gt 1.0.0-rc.1 1.0.0 && : || { echo "  FAIL: prerelease ranked above release"; failures=$((failures + 1)); }
  check semver_gt 1.0.0-beta 1.0.0-alpha
  check semver_gt 1.0.0-alpha.2 1.0.0-alpha.1
  check semver_gt 1.0.0-rc.1 1.0.0-beta
  ! semver_gt 1.0.0-alpha 1.0.0-alpha && : || { echo "  FAIL: semver_gt accepted equal prereleases"; failures=$((failures + 1)); }
  check num_gt 1 2
  ! num_gt 2 1 && : || { echo "  FAIL: num_gt accepted a regression"; failures=$((failures + 1)); }

  # release_is_monotonic should NOT die for a valid bump.
  if release_is_monotonic 0.1.1 120 0.1.0 119; then :; else echo "  FAIL: valid bump rejected"; failures=$((failures + 1)); fi
  # Same version, build advances -> valid.
  if release_is_monotonic 0.1.0 120 0.1.0 119; then :; else echo "  FAIL: same-version build bump rejected"; failures=$((failures + 1)); fi

  # Each of these must DIE (non-monotonic). Capture via a subshell so we can
  # assert the non-zero exit without terminating the whole test.
  expect_die() { if ( "$@" ) >/dev/null 2>&1; then echo "  FAIL: expected failure: $*"; failures=$((failures + 1)); fi; }
  expect_die release_is_monotonic 0.1.0 120 0.1.1 119    # downgrade version
  expect_die release_is_monotonic 0.1.0 120 0.1.0 121    # build regression
  expect_die release_is_monotonic 0.1.0 119 0.1.0 120    # build same as previous
  expect_die release_is_monotonic 1.0.0-rc.1 120 1.0.0 119 # shipping a prerelease after a release
  expect_die release_is_monotonic not.semver 120 a.b 119 # invalid versions

  # Cross-check the pure-shell semver_gt against the tested `cotype-update
  # compare` so the shell release gates and the app/CLI agree on precedence
  # (including prereleases). The tool is already built below.
  local cmp
  cmp="$(cotype_update_tool)"
  cross() {
    local a="$1" b="$2" shell_gt swift_gt
    if semver_gt "$a" "$b"; then shell_gt=0; else shell_gt=$?; fi
    if "$cmp" compare "$a" "$b" >/dev/null 2>&1; then swift_gt=0; else swift_gt=$?; fi
    if [[ "$shell_gt" != "$swift_gt" ]]; then
      echo "  FAIL: semver_gt('$a','$b')=$shell_gt but compare=$swift_gt"; failures=$((failures + 1))
    fi
  }
  cross 0.1.1 0.1.0
  cross 1.0.0 1.0.0-rc.1
  cross 1.0.0-rc.1 1.0.0
  cross 1.0.0-beta 1.0.0-alpha
  cross 1.0.0-alpha.2 1.0.0-alpha.1
  cross 1.0.0-b 0.1.0

  # xml_escape: build-app.sh writes SUFeedURL / SUPublicEDKey via this helper, so
  # it must escape XML special chars correctly.
  check_xml() { local expect="$1" input="$2" got; got="$(xml_escape "$input")"; [[ "$got" == "$expect" ]] || { echo "  FAIL: xml_escape('$input') = '$got' (expected '$expect')"; failures=$((failures + 1)); }; }
  check_xml 'a&amp;b' 'a&b'
  check_xml 'a&lt;b&gt;c' 'a<b>c'
  check_xml 'a&quot;b' 'a"b'
  check_xml 'https://x.example/a?b=1&amp;c=2' 'https://x.example/a?b=1&c=2'

  # Previous-published-manifest contract: the sed extraction that feeds
  # release_is_monotonic must read version/buildNumber from a prior manifest.
  local prev_tmp
  prev_tmp="$(mktemp -t cotype-prev.XXXXXX)"
  printf '%s' '{"version":"0.1.0","buildNumber":"41"}' > "$prev_tmp"
  pv="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$prev_tmp" | head -1)"
  pb="$(sed -n 's/.*"buildNumber":"\([^"]*\)".*/\1/p' "$prev_tmp" | head -1)"
  if [[ "$pv" != "0.1.0" || "$pb" != "41" ]]; then
    echo "  FAIL: previous-manifest extraction = version '$pv' build '$pb'"; failures=$((failures + 1))
  fi
  expect_die release_is_monotonic 0.1.0 41 "$pv" "$pb"   # same version/build -> not monotonic
  rm -f "$prev_tmp"

  # Assembling + validating a manifest with a real SHA-256 and a real key asserts
  # the JSON schema matches the Swift validator/signer.
  local tmp
  tmp="$(mktemp -d -t cotype-update-manifest.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN
  local priv pub
  priv="$(cotype_update_tool)"
  "$priv" keygen --out "$tmp" >/dev/null
  printf 'hello artifact' > "$tmp/Cotype-0.1.1.zip"
  local sha
  sha="$(shasum -a 256 "$tmp/Cotype-0.1.1.zip" | awk '{print $1}')"

  # Build an unsigned manifest via the assembly function, then write + validate.
  local manifest_json
  manifest_json="$(build_manifest_json "$tmp" "0.1.1" "120" "self-test-commit")"
  printf '%s' "$manifest_json" > "$tmp/update-manifest.json"
  if "$priv" validate --manifest "$tmp/update-manifest.json"; then :; else echo "  FAIL: assembled manifest did not validate"; failures=$((failures + 1)); fi

  # Round-trip: sign then verify with the generated key.
  "$priv" sign --manifest "$tmp/update-manifest.json" --key "$tmp/ed25519-private.key" --out "$tmp/update-manifest.signed.json" >/dev/null
  if "$priv" verify --manifest "$tmp/update-manifest.signed.json" --key "$tmp/ed25519-public.key"; then :; else echo "  FAIL: signed manifest did not verify"; failures=$((failures + 1)); fi

  # Stale archives in a reused dir must NOT leak into the generated current manifest:
  # only the exact Cotype-<version>.zip (and optional .dmg) may be declared, and a
  # dir with only stale archives must be rejected.
  local stale mj
  stale="$(mktemp -d -t cotype-stale-manifest.XXXXXX)"
  printf 'old' > "$stale/Cotype-0.0.0.zip"
  printf 'old' > "$stale/Cotype-0.0.0.dmg"
  printf 'cur' > "$stale/Cotype-0.1.1.zip"
  mj="$(build_manifest_json "$stale" "0.1.1" "121" "stale-test")"
  if printf '%s' "$mj" | grep -q 'Cotype-0.0.0'; then
    echo "  FAIL: stale archive leaked into current manifest"; failures=$((failures + 1))
  fi
  if ! printf '%s' "$mj" | grep -q '"filename":"Cotype-0.1.1.zip"'; then
    echo "  FAIL: current archive missing from current manifest"; failures=$((failures + 1))
  fi
  rm -f "$stale/Cotype-0.1.1.zip"
  # Subshell so build_manifest_json's die() (which exits) only fails the check.
  if ( build_manifest_json "$stale" "0.1.1" "121" "stale-test" ) >/dev/null 2>&1; then
    echo "  FAIL: dir with only stale archives was not rejected"; failures=$((failures + 1))
  fi
  # A DMG is optional metadata/distribution convenience; Sparkle's canonical ZIP
  # is mandatory for the current release contract.
  printf 'cur-dmg-only' > "$stale/Cotype-0.1.1.dmg"
  if ( build_manifest_json "$stale" "0.1.1" "121" "stale-test" ) >/dev/null 2>&1; then
    echo "  FAIL: current DMG without current ZIP was not rejected"; failures=$((failures + 1))
  fi
  rm -rf "$stale"

  trap - RETURN
  rm -rf "$tmp"

  if [[ "$failures" -ne 0 ]]; then
    die "self-test failed: $failures check(s)"
  fi
  echo "update-manifest self-test: all checks passed"
  exit 0
}

# ---------------------------------------------------------------------------
# Manifest assembly. Writes no files; echoes the canonical (unsigned) JSON.
# Takes the release dir, version, build number, and commit as a positional args
# so it can be reused by self-test without touching the release path.
# ---------------------------------------------------------------------------
build_manifest_json() {
  local dir="$1" version="$2" build="$3" commit="$4"
  local artifact_json=""
  local first=1

  # Select ONLY the exact current-version archive(s): Cotype-${version}.zip and
  # (optionally) Cotype-${version}.dmg. Never glob Cotype-*, so a reused release
  # dir holding stale earlier archives cannot leak into the current manifest (and
  # therefore cannot be uploaded by publish-update.sh). Historical archives are
  # left in place for appcast generation. Reject absence outright.
  local zip="$dir/Cotype-${version}.zip"
  local dmg="$dir/Cotype-${version}.dmg"
  [[ -f "$zip" ]] || die "No current Sparkle archive in $dir (expected Cotype-${version}.zip)."
  local candidates=("$zip")
  [[ -f "$dmg" ]] && candidates+=("$dmg")

  local file kind size sha url
  for file in "${candidates[@]}"; do
    if [[ "$file" == *.zip ]]; then kind="zip"; elif [[ "$file" == *.dmg ]]; then kind="dmg"; else kind="app"; fi
    size="$(stat -f '%z' "$file")"
    sha="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ -n "$CHANNEL_URL" ]]; then
      url="$CHANNEL_URL/$(basename "$file")"
    else
      url="$(basename "$file")"
    fi
    [[ "$first" == "0" ]] && artifact_json+=",$(printf '\n')"
    first=0
    artifact_json+="{"
    artifact_json+="\"filename\":\"$(basename "$file")\","
    artifact_json+="\"kind\":\"$kind\","
    artifact_json+="\"size\":$size,"
    artifact_json+="\"sha256\":\"$sha\","
    artifact_json+="\"url\":\"$url\""
    artifact_json+="}"
  done

  printf '{'
  printf '"schemaVersion":1,'
  printf '"appIdentifier":"%s",' "$COTYPE_BUNDLE_ID"
  printf '"product":"%s",' "$COTYPE_PRODUCT"
  printf '"version":"%s",' "$version"
  printf '"buildNumber":"%s",' "$build"
  printf '"minimumOSVersion":"%s",' "$MIN_OS"
  printf '"commit":"%s",' "$commit"
  printf '"buildMode":"%s",' "$COTYPE_BUILD_MODE"
  printf '"createdAt":"%s",' "$COTYPE_BUILD_DATE"
  printf '"artifacts":[%s]' "$artifact_json"
  printf '}'
  printf '\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
  self_test
fi

RELEASE_DIR="${RELEASE_DIR:-$COTYPE_DIST/release}"
[[ -d "$RELEASE_DIR" ]] || die "Release directory not found: $RELEASE_DIR (run package-release.sh first)."

# Monotonicity is enforced against a PREVIOUS PUBLISHED manifest, not just a
# local output dir. Precedence: --previous-manifest <file>, then
# COTYPE_PREVIOUS_MANIFEST <file> (what CI sets after fetching the published
# update-manifest.json), then the local $OUT_DIR/update-manifest.json. A fresh CI
# output dir therefore still enforces monotonicity across releases.
MONOTONIC_CHECK=""
PREVIOUS_MANIFEST="${PREVIOUS_MANIFEST_FILE:-${COTYPE_PREVIOUS_MANIFEST:-}}"
if [[ -z "$PREVIOUS_MANIFEST" ]]; then
  PREVIOUS_MANIFEST="$RELEASE_DIR/update-manifest.json"
fi
if [[ -f "$PREVIOUS_MANIFEST" ]]; then
  PREV_VERSION="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$PREVIOUS_MANIFEST" | head -1)"
  PREV_BUILD="$(sed -n 's/.*"buildNumber":"\([^"]*\)".*/\1/p' "$PREVIOUS_MANIFEST" | head -1)"
  MONOTONIC_CHECK=1
fi
release_is_monotonic "$COTYPE_VERSION" "$COTYPE_BUILD_NUMBER" "${PREV_VERSION:-}" "${PREV_BUILD:-}"

MANIFEST="$(build_manifest_json "$RELEASE_DIR" "$COTYPE_VERSION" "$COTYPE_BUILD_NUMBER" "$COTYPE_GIT_COMMIT")"
OUT="$RELEASE_DIR/update-manifest.json"

if [[ -n "$SIGN_WITH" ]]; then
  [[ -f "$SIGN_WITH" ]] || die "Signing key not found: $SIGN_WITH"
  TMP_JSON="$(mktemp -t cotype-update-manifest.XXXXXX).json"
  trap 'rm -f "${TMP_JSON:-}"' EXIT
  printf '%s' "$MANIFEST" > "$TMP_JSON"
  log "Signing update manifest with '$SIGN_WITH'…"
  "$(cotype_update_tool)" sign --manifest "$TMP_JSON" --key "$SIGN_WITH" --out "$OUT"
  # Validate the signed manifest (structure + signature presence).
  "$(cotype_update_tool)" validate --manifest "$OUT" --require-signature
  rm -f "$TMP_JSON"
  trap - EXIT
  log "Signed update manifest written to $OUT"
else
  if [[ "$REQUIRE_SIGNATURE" == "1" ]]; then
    die "--require-signature is set but no signing key was provided (use --sign-with <private.key>)."
  fi
  printf '%s' "$MANIFEST" > "$OUT"
  warn "Wrote UNSIGNED update manifest to $OUT. This is only safe for a private/personal channel."
  warn "For a public channel, sign it with --sign-with <ed25519-private.key> (and --require-signature)."
fi

echo
echo "Update manifest:"
echo "  $OUT"
echo "  version: $COTYPE_VERSION  build: $COTYPE_BUILD_NUMBER  commit: $COTYPE_GIT_COMMIT"
[[ -n "$MONOTONIC_CHECK" ]] && echo "  monotonicity: checked (previous ${PREV_VERSION:-?} build ${PREV_BUILD:-?})"
echo "  signature: $([[ -n "$SIGN_WITH" ]] && echo signed || echo unsigned)"
