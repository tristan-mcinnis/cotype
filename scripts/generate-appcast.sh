#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Generate a Sparkle appcast.xml for the Cotype update feed using Sparkle's OWN
# pinned tools (the ones shipped in the SPM artifact), and guarantee a valid
# EdDSA-signed feed whose key MATCHES the app's embedded SUPublicEDKey.
#
#   ./scripts/generate-appcast.sh --release-dir dist/release \
#       --private-key ~/.cotype-update/ed25519-private.key \
#       --channel-url https://updates.example.com/cotype
#
# Options:
#   --release-dir <dir>   Directory containing Cotype-<version>.zip/.dmg (default: dist/release)
#   --private-key <file>  Path to a file whose CONTENTS are the 44-char base64
#                         EdDSA private key (never the raw/decoded bytes).
#   --channel-url <url>   Base URL prefix for enclosure URLs (absolute; '/'
#                         normalized to a trailing slash).
#   --self-test           Run the pinned tool + key-pair verification against a
#                         built archive; exit 0/1.
#   --help

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

RELEASE_DIR="${COTYPE_RELEASE_DIR:-$COTYPE_DIST/release}"
PRIVATE_KEY=""
CHANNEL_URL=""
SELF_TEST=0

_find_tool() {
  local path="$1"
  if [[ -x "$path" ]]; then printf '%s' "$path"; return; fi
  if has_command "$(basename "$path")"; then printf '%s' "$(command -v "$(basename "$path")")"; return; fi
  die "Sparkle tool not found at $path. Run \`swift build --product cotype-menu\` first."
}

TOOL_DIR="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$(_find_tool "$TOOL_DIR/generate_appcast")"
SIGN_UPDATE="$(_find_tool "$TOOL_DIR/sign_update")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir) RELEASE_DIR="$2"; shift 2 ;;
    --private-key) PRIVATE_KEY="$2"; shift 2 ;;
    --channel-url) CHANNEL_URL="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Manifest / archive helpers
# ---------------------------------------------------------------------------
manifest_version_build() {
  local mf="$1"
  local v b
  v="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$mf")"
  b="$(sed -n 's/.*"buildNumber":"\([^"]*\)".*/\1/p' "$mf")"
  v="${v%%$'\n'*}"
  b="${b%%$'\n'*}"
  # Trailing newline so `read -r a b < <(…)` returns 0 (no EOF before newline).
  printf '%s %s\n' "$v" "$b"
}

# Extract a plist from the current app archive (root app bundle is "Cotype.app").
archive_plist() {
  local zip="$1"
  local tmp
  tmp="$(mktemp -t cotype-info.XXXXXX)"
  if ! unzip -p "$zip" "Cotype.app/Contents/Info.plist" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  printf '%s' "$tmp"
}
plist_raw() { plutil -extract "$2" raw "$1" 2>/dev/null || echo ""; }
archive_raw() { local t; t="$(archive_plist "$1")" || return 1; plist_raw "$t" "$2"; rm -f "$t"; }

# The exact version that should be released: COTYPE_VERSION override, else the
# manifest's version, else the sole Cotype-*.zip's version. Dies on ambiguity.
current_release_version() {
  if [[ -n "${COTYPE_VERSION:-}" ]]; then printf '%s' "$COTYPE_VERSION"; return; fi
  if [[ -f "$RELEASE_DIR/update-manifest.json" ]]; then
    read -r v _ <<< "$(manifest_version_build "$RELEASE_DIR/update-manifest.json")"
    [[ -n "$v" ]] && { printf '%s' "$v"; return; }
  fi
  local zips
  zips="$(ls "$RELEASE_DIR"/Cotype-*.zip 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$zips" == "1" ]]; then
    local base
    base="$(basename "$(ls "$RELEASE_DIR"/Cotype-*.zip 2>/dev/null | head -1)")"
    base="${base#Cotype-}"; base="${base%.zip}"
    printf '%s' "$base"
    return
  fi
  [[ "$zips" == "0" ]] && die "No Cotype-*.zip in $RELEASE_DIR (and no update-manifest.json to determine the version)."
  die "Multiple Cotype-*.zip with no update-manifest.json; cannot determine the intended version."
}

# Select the EXACT current-version archive (never the lexicographically-first
# stale one), and assert its CFBundleVersion matches the expected build.
select_current_archive() {
  local dir="$1" version="$2" build="${3:-}" file ext=zip
  local candidates
  candidates="$(ls "$dir"/Cotype-${version}.zip 2>/dev/null || true)"
  if [[ -z "$candidates" ]]; then
    candidates="$(ls "$dir"/Cotype-${version}.dmg 2>/dev/null || true)"; ext=dmg
  fi
  if [[ -z "$candidates" ]]; then
    die "No archive Cotype-${version}.zip/.dmg in $dir (expected the current version; stale/old archives are rejected)."
  fi
  if [[ "$(printf '%s\n' "$candidates" | grep -c .)" -gt 1 ]]; then
    die "Ambiguous archives for version ${version}: $candidates"
  fi
  file="$(printf '%s\n' "$candidates" | head -1)"
  if [[ -n "$build" ]]; then
    local actual
    actual="$(archive_raw "$file" CFBundleVersion)"
    if [[ -z "$actual" || "$actual" != "$build" ]]; then
      die "Archive $file has CFBundleVersion '$actual' but expected '$build'. Refusing a stale/mismatched archive."
    fi
  fi
  printf '%s' "$file"
}

# Validate that a file's contents are a base64 Ed25519 private key (44 chars ->
# 32 bytes) so an erroneously-decoded secret fails fast.
validate_key_b64() {
  local f="$1" content
  [[ -f "$f" ]] || die "Private key file not found: $f"
  content="$(tr -d '[:space:]' < "$f")"
  if ! [[ "$content" =~ ^[A-Za-z0-9+/]{42}==$ || "$content" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    die "Private key file '$f' is not a 44-char base64 EdDSA key (got ${#content} chars). The secret must be the base64 TEXT, not decoded raw bytes."
  fi
  printf '%s' "$content"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
  # Build a release archive with the generated MATCHING public key so the key-pair
  # verification passes for real (not just an attribute grepped).
  if [[ ! -f "$ROOT/dist/release/Cotype-"*.zip ]]; then
    warn "No built release archive; producing one for the self-test…"
  fi
  KEYDIR="$(mktemp -d -t cotype-selftest-key.XXXXXX)"
  "$(cotype_update_tool)" keygen --out "$KEYDIR" >/dev/null 2>&1
  PRIVATE_KEY="$KEYDIR/ed25519-private.key"
  PUB_B64="$(cat "$KEYDIR/ed25519-public.key")"
  CHANNEL_URL="https://updates.example.com/cotype"

  # 1) Verify the real cryptographic pair: derive-public must match keygen output.
  DERIVED="$("$(cotype_update_tool)" derive-public --private-key "$PRIVATE_KEY")"
  [[ "$DERIVED" == "$PUB_B64" ]] || { echo "FAIL: derive-public mismatch"; exit 1; }
  echo "  key pair OK (derive-public matches keygen public key)"

  # 2) Build an app that embeds the matching public key (test override), then archive.
  COTYPE_EMBED_UPDATE_CONFIG=1 \
  COTYPE_UPDATE_FEED_URL="$CHANNEL_URL" \
  COTYPE_UPDATE_PUBLIC_KEY="$PUB_B64" \
    COTYPE_SIGN_IDENTITY=- "$ROOT/scripts/build-app.sh" >/dev/null 2>&1
  rm -f "$ROOT/dist/release"/Cotype-*.zip "$ROOT/dist/release"/Cotype-*.dmg "$ROOT/dist/release"/update-manifest.json
  "$ROOT/scripts/package-release.sh" --allow-personal --channel-url "$CHANNEL_URL" >/dev/null 2>&1 || true

  RELEASE_DIR="$ROOT/dist/release"
fi

[[ -n "$PRIVATE_KEY" ]] || die "--private-key is required (path to a file containing the base64 EdDSA private key)."
[[ -n "$CHANNEL_URL" ]] || die "--channel-url is required (artifacts must be addressable by absolute URL)."
[[ -d "$RELEASE_DIR" ]] || die "Release dir not found: $RELEASE_DIR"

KEY_B64="$(validate_key_b64 "$PRIVATE_KEY")"
KEY_FILE="$(mktemp -t cotype-sparkle-key.XXXXXX)"
STAGING_DIR="$(mktemp -d -t cotype-appcast.XXXXXX)"
trap 'rm -f "$KEY_FILE"; rm -rf "$STAGING_DIR"; rm -rf "${KEYDIR:-}"' EXIT
printf '%s' "$KEY_B64" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

COTYPE_VERSION="${COTYPE_VERSION:-$(current_release_version)}"
read -r _ MANIFEST_BUILD < <(manifest_version_build "$RELEASE_DIR/update-manifest.json" 2>/dev/null || printf ' ')
BUILD="${COTYPE_BUILD_NUMBER:-$MANIFEST_BUILD}"

# Select the exact current-version archive, restoring a prior appcast for merge.
ZIP="$(select_current_archive "$RELEASE_DIR" "$COTYPE_VERSION" "$BUILD")"
cp "$ZIP" "$STAGING_DIR/"
if [[ -f "$RELEASE_DIR/appcast.xml" ]]; then cp "$RELEASE_DIR/appcast.xml" "$STAGING_DIR/"; fi
log "Using canonical archive: $(basename "$ZIP") (version $COTYPE_VERSION, build $BUILD)"

# KEY-PAIR VERIFICATION: the private key must match the app's embedded SUPublicEDKey.
DERIVED_PUB="$("$(cotype_update_tool)" derive-public --private-key "$PRIVATE_KEY")"
APP_PUB="$(archive_raw "$ZIP" SUPublicEDKey)"
if [[ -z "$APP_PUB" ]]; then
  die "Archive has no SUPublicEDKey (not a release-candidate build). Refusing to sign a feed for an app that cannot verify it."
fi
if [[ "$DERIVED_PUB" != "$APP_PUB" ]]; then
  die "The signing private key does NOT match the app's embedded SUPublicEDKey.
  derived: $DERIVED_PUB
  app:     $APP_PUB"
fi
log "Signing key matches the app's embedded SUPublicEDKey (Ed25519 pair verified)."

log "Running pinned generate_appcast (ed-key-file + download-url-prefix)…"
NRM_URL="${CHANNEL_URL%/}/"
"$GENERATE_APPCAST" --ed-key-file "$KEY_FILE" --download-url-prefix "$NRM_URL" "$STAGING_DIR"

APPCAST="$STAGING_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || die "generate_appcast did not produce $APPCAST"

# Fill any enclosure missing an EdDSA signature with Sparkle's own sign_update.
# Cryptographic validity is guaranteed by the key-pair match above (the signing key
# derives the exact public key embedded in the app's SUPublicEDKey), so a
# signature produced by it is valid for the archived app. We still assert every
# enclosure carries a signature below.
python3 - "$STAGING_DIR" "$KEY_FILE" "$SIGN_UPDATE" <<'PY'
import sys, subprocess, re, os
staging, key, sign_update = sys.argv[1], sys.argv[2], sys.argv[3]
appcast = os.path.join(staging, "appcast.xml")
xml = open(appcast, "r", encoding="utf-8").read()
def sig_for(local):
    r = subprocess.run([sign_update, "--ed-key-file", key, "-p", local], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None
def patch(m):
    encl = m.group(0)
    if 'sparkle:edSignature=' in encl: return encl
    url = re.search(r'url="([^"]+)"', encl)
    if not url: return encl
    fname = url.group(1).rsplit("/", 1)[-1]
    local = os.path.join(staging, fname)
    if not os.path.exists(local): return encl
    sig = sig_for(local)
    if not sig: return encl
    return encl.replace("/>", ' sparkle:edSignature="%s"/>' % sig, 1)
xml = re.sub(r'<enclosure\b[^>]*/>', patch, xml)
open(appcast, "w", encoding="utf-8").write(xml)
PY

SIG_COUNT="$(grep -c 'sparkle:edSignature=' "$APPCAST" || true)"
ITEM_COUNT="$(grep -c '<enclosure' "$APPCAST" || true)"
if [[ "$SIG_COUNT" -eq 0 || "$SIG_COUNT" -lt "$ITEM_COUNT" ]]; then
  die "Appcast has $SIG_COUNT/$ITEM_COUNT enclosures signed; refusing to publish an unsigned feed."
fi

cp "$APPCAST" "$RELEASE_DIR/appcast.xml"
log "Wrote $RELEASE_DIR/appcast.xml (signed+verified: $SIG_COUNT/$ITEM_COUNT enclosures)"
log "Publish $RELEASE_DIR/appcast.xml and the artifacts so SUFeedURL resolves."

if [[ "$SELF_TEST" == "1" ]]; then
  # Prove exact-archive selection: a stale lexicographically-earlier archive must
  # NOT be chosen over the current version.
  STALE="$(mktemp -d -t cotype-stale.XXXXXX)"
  cp "$ROOT/dist/release/Cotype-$COTYPE_VERSION.zip" "$STALE/Cotype-0.0.0.zip"
  cp "$ROOT/dist/release/Cotype-$COTYPE_VERSION.zip" "$STALE/Cotype-$COTYPE_VERSION.zip"
  CHOSEN="$(select_current_archive "$STALE" "$COTYPE_VERSION" "$BUILD")"
  [[ "$(basename "$CHOSEN")" == "Cotype-$COTYPE_VERSION.zip" ]] || { echo "FAIL: stale archive selected: $(basename "$CHOSEN")"; exit 1; }
  rm -rf "$STALE"
  echo "generate-appcast self-test: OK (pinned tool signed+verified $SIG_COUNT/$ITEM_COUNT enclosures; key pair verified; exact archive chosen)"
  exit 0
fi
