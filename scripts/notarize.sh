#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# OPTIONAL Developer ID + Hardened Runtime + notarization wrapper. This is the
# documented opt-in release path. It NEVER runs as part of the default build or
# install. If the required identity or notarization credential is not present,
# it fails loudly instead of claiming success.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

APP="${1:-$COTYPE_DIST_APP}"
DEVELOPER_ID="${COTYPE_DEVELOPER_ID_APP:-${COTYPE_SIGN_IDENTITY:-}}"
STAPLE=1
SUBMIT=1

usage() {
  cat <<'EOF'
Usage: ./scripts/notarize.sh [--no-staple] [--no-submit] [app]

Notarize and staple a Developer ID-signed Cotype.app.

Required environment:
  COTYPE_DEVELOPER_ID_APP   The Developer ID Application identity
                            (e.g. "Developer ID Application: Name (TEAMID)").
  NOTARTOOL_APPLE_ID / NOTARTOOL_TEAM_ID / NOTARTOOL_PASSWORD
                            or an App Store Connect API key
                            (NOTARTOOL_KEY_ID / NOTARTOOL_ISSUER / NOTARTOOL_KEY).
                            These map to `xcrun notarytool submit`.

The app must already be signed with the Developer ID identity and Hardened
Runtime enabled. This script fails (non-zero) if the credentials are absent.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-staple) STAPLE=0; shift ;;
    --no-submit) SUBMIT=0; shift ;;
    --help|-h) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) APP="$1"; shift ;;
  esac
done

if ! has_command notarytool && ! xcrun --find notarytool >/dev/null 2>&1; then
  die "notarytool is not available."
fi
readonly NOTARYTOOL="$(xcrun --find notarytool)"

if [[ -z "$DEVELOPER_ID" ]]; then
  die "No Developer ID Application identity found. Set COTYPE_DEVELOPER_ID_APP. This is the opt-in release path and is intentionally not configured by default."
fi
if [[ "$DEVELOPER_ID" == "-" ]]; then
  die "Resolved identity is ad-hoc; a Developer ID Application identity is required for notarization."
fi

# Confirm the app is signed with the Developer ID before submitting.
if ! codesign -dv "$APP" 2>&1 | grep -q "Developer ID Application"; then
  die "$APP is not signed with a Developer ID Application identity. Rebuild with COTYPE_SIGN_IDENTITY set and Hardened Runtime enabled first."
fi
if ! codesign -dv "$APP" 2>&1 | grep -q "runtime"; then
  warn "Hardened Runtime is not enabled on $APP. Distribution builds should sign with --options runtime."
fi

# Notarization is a *runtime* step: the build must already be signed with a
# Developer ID Application identity and Hardened Runtime. The Info.plist is NOT
# pre-stamped as notarized (that would be a lie before notarization succeeds);
# the About pane derives the real notarized state from Gatekeeper after this step.

# Sign nested code first, then the outer app, all with Hardened Runtime and a
# secure timestamp. Notarization rejects partially or inconsistently signed code.
log "Re-signing with Hardened Runtime using '$DEVELOPER_ID'…"
FRAMEWORK="$APP/Contents/Frameworks/llama.framework"
[[ -d "$FRAMEWORK" ]] || die "Embedded llama.framework is missing."
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$FRAMEWORK"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"

if [[ "$SUBMIT" == "1" ]]; then
  AUTH_ARGS=()
  # The secret credential is the Apple ID app password (or the API key *file
  # content*). `notarytool` reads the API key from the file path given by --key
  # (the path is not itself secret), so only the password must be kept out of
  # argv. It is referenced as @env: so the real value never appears in the
  # process argument list, which any process on the machine can read via `ps`.
  if [[ -n "${NOTARTOOL_KEY_ID:-}" && -n "${NOTARTOOL_ISSUER:-}" && -n "${NOTARTOOL_KEY:-}" ]]; then
    AUTH_ARGS=(--key "$NOTARTOOL_KEY" --key-id "$NOTARTOOL_KEY_ID" --issuer "$NOTARTOOL_ISSUER")
  elif [[ -n "${NOTARTOOL_APPLE_ID:-}" && -n "${NOTARTOOL_TEAM_ID:-}" && -n "${NOTARTOOL_PASSWORD:-}" ]]; then
    AUTH_ARGS=(--apple-id "$NOTARTOOL_APPLE_ID" --team-id "$NOTARTOOL_TEAM_ID" --password "@env:NOTARTOOL_PASSWORD")
  else
    die "Missing notarytool credentials. Configure App Store Connect key or Apple ID credentials."
  fi

  # notarytool accepts zip/pkg/dmg containers, not a bare .app bundle.
  SUBMISSION_ZIP="$(mktemp -t cotype-notary).zip"
  trap 'rm -f "${SUBMISSION_ZIP:-}"' EXIT
  ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
  log "Submitting for notarization…"
  "$NOTARYTOOL" submit "$SUBMISSION_ZIP" --wait "${AUTH_ARGS[@]}"
  rm -f "$SUBMISSION_ZIP"
  trap - EXIT
fi

if [[ "$STAPLE" == "1" ]]; then
  xcrun --find stapler >/dev/null 2>&1 || die "stapler is not available."
  log "Stapling ticket…"
  xcrun stapler staple "$APP"
fi

log "Verifying notarization…"
codesign --verify --deep --strict --verbose=2 "$APP" || die "codesign verification failed."
if [[ "$STAPLE" == "1" ]]; then
  xcrun stapler validate "$APP" || die "Stapled ticket validation failed."
fi
if has_command spctl; then
  spctl -a -vvv -t exec "$APP" || die "Gatekeeper rejected the notarized app."
fi

log "Notarization and Gatekeeper verification passed."
