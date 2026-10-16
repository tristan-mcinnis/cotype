#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Create a versioned, checksummed distribution archive from dist/Cotype.app.
# Produces a .zip (and, when the `dmg` tool is available, a .dmg) with a
# printed SHA-256 and a small release-notes file. Used by the release path; the
# personal install path does not need it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

APP="$COTYPE_DIST_APP"
ALLOW_PERSONAL=0
SIGN_WITH=""
REQUIRE_SIGNATURE=0
CHANNEL_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-personal) ALLOW_PERSONAL=1; shift ;;
    --sign-with) SIGN_WITH="$2"; shift 2 ;;
    --require-signature) REQUIRE_SIGNATURE=1; shift ;;
    --channel-url) CHANNEL_URL="$2"; shift 2 ;;
    --previous-manifest) PREVIOUS_MANIFEST_FILE="$2"; shift 2 ;;
    --help|-h) echo "Usage: ./scripts/package-release.sh [--allow-personal] [--sign-with <private.key>] [--require-signature] [--channel-url <base>] [--previous-manifest <path>] [app]"; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) APP="$1"; shift ;;
  esac
done
OUT_DIR="${COTYPE_RELEASE_DIR:-$COTYPE_DIST/release}"
TAG="$COTYPE_VERSION"

[[ -d "$APP" ]] || die "App bundle not found: $APP (run ./scripts/build-app.sh first)."

# Cotype targets Apple Silicon only; refuse to package a non-arm64 release.
require_apple_silicon_host
require_arm64 "$APP/Contents/MacOS/$COTYPE_APP_NAME"

# Release monotonicity is enforced here, before any artifact is written, using
# the PREVIOUS PUBLISHED manifest. Precedence: --previous-manifest, then
# COTYPE_PREVIOUS_MANIFEST (set by CI after fetching the published manifest), then
# the local output dir. A fresh CI output dir therefore still enforces monotonicity
# across releases.
PREVIOUS_MANIFEST="${PREVIOUS_MANIFEST_FILE:-${COTYPE_PREVIOUS_MANIFEST:-}}"
if [[ -z "$PREVIOUS_MANIFEST" ]] && [[ -f "$OUT_DIR/update-manifest.json" ]]; then
  PREVIOUS_MANIFEST="$OUT_DIR/update-manifest.json"
fi
if [[ -n "$PREVIOUS_MANIFEST" && -f "$PREVIOUS_MANIFEST" ]]; then
  PV="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$PREVIOUS_MANIFEST" | head -1)"
  PB="$(sed -n 's/.*"buildNumber":"\([^"]*\)".*/\1/p' "$PREVIOUS_MANIFEST" | head -1)"
  release_is_monotonic "$COTYPE_VERSION" "$COTYPE_BUILD_NUMBER" "$PV" "$PB"
fi

# A production release needs the channel base URL so the manifest/appcast and
# artifact URLs are absolute (relative URLs cannot be downloaded by an app).
if [[ "$REQUIRE_SIGNATURE" == "1" && -z "$CHANNEL_URL" ]]; then
  die "--require-signature requires --channel-url <base> (a release feed must use absolute artifact URLs)."
fi
NOTARIZED=no
# Notarization requires the STRICT assessment (verbose source 'Notarized Developer
# ID' + a Developer ID Application codesign authority), not merely a stapler
# ticket or any `spctl` exit-0.
if is_notarized_strict "$APP"; then
  NOTARIZED=yes
elif [[ "$ALLOW_PERSONAL" != "1" ]]; then
  die "Refusing to create a release artifact from an unnotarized app. Use --allow-personal only for a clearly labeled private build."
fi
mkdir -p "$OUT_DIR"

LOG="${OUT_DIR}/release-notes-${TAG}.txt"
cat > "$LOG" <<EOF
Cotype $TAG
===========
Build: $COTYPE_BUILD_NUMBER
Git commit: $COTYPE_GIT_COMMIT
Bundle ID: $COTYPE_BUNDLE_ID
Model: $COTYPE_MODEL_FILENAME ($COTYPE_MODEL_LICENSE)
llama.cpp build: $COTYPE_LLAMA_BUILD ($COTYPE_LLAMA_LICENSE)
Signing identity: $(sign_identity_label "$(resolve_sign_identity)")
Notarized: $NOTARIZED
Distribution: $([[ "$NOTARIZED" == "yes" ]] && echo "Developer ID / notarized" || echo "private personal build; not for public distribution")
EOF

ZIP="$OUT_DIR/Cotype-${TAG}.zip"
log "Archiving $ZIP …"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
LOG="${LOG}"

if has_command hdiutil; then
  DMG="$OUT_DIR/Cotype-${TAG}.dmg"
  log "Building $DMG …"
  rm -f "$DMG"
  hdiutil create -volname "Cotype" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
  DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  printf '\nDMG SHA-256: %s\n' "$DMG_SHA" >> "$LOG"
fi

printf '\nZIP SHA-256: %s\n' "$SHA" >> "$LOG"

echo
echo "Release artifacts:"
echo "  $ZIP"
[[ -n "${DMG:-}" ]] && echo "  $DMG"
echo "  $LOG"
echo
echo "ZIP SHA-256: $SHA"
[[ -n "${DMG_SHA:-}" ]] && echo "DMG SHA-256: $DMG_SHA"

echo
echo "--- update manifest ---"
# UPDATE_CMD always holds at least the script path so the array is never empty
# under `set -u` (bash 3.2 treats an empty "${arr[@]}" as unbound).
UPDATE_CMD=("$ROOT/scripts/update-manifest.sh")
[[ -n "$SIGN_WITH" ]] && UPDATE_CMD+=(--sign-with "$SIGN_WITH")
[[ "$REQUIRE_SIGNATURE" == "1" ]] && UPDATE_CMD+=(--require-signature)
[[ -n "$CHANNEL_URL" ]] && UPDATE_CMD+=(--channel-url "$CHANNEL_URL")
[[ -n "$PREVIOUS_MANIFEST" ]] && UPDATE_CMD+=(--previous-manifest "$PREVIOUS_MANIFEST")
UPDATE_CMD+=("$OUT_DIR")
"${UPDATE_CMD[@]}"
