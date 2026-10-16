#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Build a signed Cotype.app bundle with stable version stamping.
#
# Output:  dist/Cotype.app (and dist/Cotype.icns source artifacts)
#
# Options:
#   --identity <name>   Sign with a specific codesigning identity (overrides
#                       COTYPE_SIGN_IDENTITY and the persisted identity).
#   --mode <name>       Build mode stamped into Info.plist (default: development).
#   --info              Print the resolved version/signing/framework metadata and exit.
#   --help              Show this help.
#
# Signing is ad-hoc ("-") when no Apple Development / Developer ID identity is
# present (e.g. CI). This build is NOT notarized; see docs/RELEASE.md for the
# documented opt-in Developer ID + notarization path.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

identity=""
mode="$COTYPE_BUILD_MODE"
# A build cannot be *notarized* at build time. --notarize (or COTYPE_NOTARIZED=1)
# marks the output as a Developer ID **release candidate**: signed with the
# Developer ID Application identity and Hardened Runtime, stamped with
# CotypeReleaseCandidate=true, but with CotypeNotarized=false until notarization
# actually succeeds. The About pane derives notarized status at runtime from
# Gatekeeper, so it never claims notarization from this build-time flag.
NOTARIZED="${COTYPE_NOTARIZED:-0}"
if [[ "$NOTARIZED" == "1" || "$NOTARIZED" == "true" ]]; then NOTARIZED=1; else NOTARIZED=0; fi

usage() { sed -n '2,20p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)   identity="$2"; shift 2 ;;
    --mode)       mode="$2"; shift 2 ;;
    --notarize)   NOTARIZED=1; shift ;;
    --info)       info_mode=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    *)            die "Unknown option: $1" ;;
  esac
done

if [[ "$NOTARIZED" == "1" ]]; then
  if [[ "$mode" != "release" ]]; then
    warn "--notarize requested but mode is '$mode' (release builds should set --mode release). Forcing --mode release."
    mode="release"
  fi
fi

# Resolve metadata + signing identity up front so --info and build agree.
if [[ -n "$identity" ]]; then
  COTYPE_SIGN_IDENTITY="$identity"
fi
SIGN_IDENTITY="$(resolve_sign_identity)"
# Apple-Silicon-only packaging: fail clearly on a non-arm64 host rather than
# depending on the runner label.
require_apple_silicon_host

# A notarized release must be signed by a Developer ID Application identity with
# Hardened Runtime. Refuse to stamp an app as notarized when it cannot be.
if [[ "$NOTARIZED" == "1" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]] || [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    die "--notarize requires a Developer ID Application signing identity (got '$(sign_identity_label "$SIGN_IDENTITY")'). Set COTYPE_SIGN_IDENTITY and retry."
  fi
  # A public release candidate must ship a COMPLETE Sparkle update config: an
  # HTTPS feed base URL AND a valid 32-byte base64 Ed25519 public key. A missing
  # or malformed config would ship an app whose updater is broken, so fail loudly.
  if [[ -z "${COTYPE_UPDATE_FEED_URL:-}" ]]; then
    die "--notarize requires COTYPE_UPDATE_FEED_URL (HTTPS Sparkle feed base). A release candidate must configure updates; CI must set it."
  fi
  if [[ -z "${COTYPE_UPDATE_PUBLIC_KEY:-}" ]]; then
    die "--notarize requires COTYPE_UPDATE_PUBLIC_KEY (base64 Ed25519 public key). A release candidate must configure updates; CI must set it."
  fi
  case "$COTYPE_UPDATE_FEED_URL" in
    https://*) : ;;
    *) die "COTYPE_UPDATE_FEED_URL must be an HTTPS URL (got '$COTYPE_UPDATE_FEED_URL')." ;;
  esac
  if ! [[ "${COTYPE_UPDATE_PUBLIC_KEY}" =~ ^[A-Za-z0-9+/]{42}==$ || "${COTYPE_UPDATE_PUBLIC_KEY}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    die "COTYPE_UPDATE_PUBLIC_KEY is not a 44-char base64 Ed25519 public key (got ${#COTYPE_UPDATE_PUBLIC_KEY} chars)."
  fi
fi

# ---------------------------------------------------------------------------
# Build the product FIRST so the SwiftPM artifacts (llama, Sparkle) exist on a
# clean checkout before we look them up. Resolving/building before lookup is what
# lets `./scripts/build-app.sh` (and `--info`) work from a fresh clone.
# ---------------------------------------------------------------------------
log "Building release product '$COTYPE_PRODUCT'…"
swift build -c release --product "$COTYPE_PRODUCT"

BINARY="$ROOT/.build/release/$COTYPE_PRODUCT"
# Cotype targets Apple Silicon only; refuse a release bundle from a non-arm64 binary.
require_arm64 "$BINARY"
LLAMA_FRAMEWORK="$(find_llama_framework)"
SPARKLE_FRAMEWORK="$(find_sparkle_framework)"

if [[ "${info_mode:-0}" == "1" ]]; then
  echo "Cotype build metadata"
  echo "  product           : $COTYPE_PRODUCT"
  echo "  version           : $COTYPE_VERSION"
  echo "  build number      : $COTYPE_BUILD_NUMBER"
  echo "  git commit        : $COTYPE_GIT_COMMIT (dirty: $COTYPE_GIT_DIRTY)"
  echo "  build date        : $COTYPE_BUILD_DATE"
  echo "  bundle id         : $COTYPE_BUNDLE_ID"
  echo "  build mode        : $mode"
  echo "  signing identity  : $(sign_identity_label "$SIGN_IDENTITY")"
  echo "  llama.cpp build   : $COTYPE_LLAMA_BUILD"
  echo "  model license     : $COTYPE_MODEL_LICENSE"
  echo "  notarized         : $([[ "$NOTARIZED" == "1" ]] && echo 'no (Developer ID release candidate; must be notarized before release)' || echo 'no (personal build)')"
  echo "  release candidate : $([[ "$NOTARIZED" == "1" ]] && echo yes || echo no)"
  echo "  sparkle feed      : $([[ "$NOTARIZED" == "1" && -n "${COTYPE_UPDATE_FEED_URL:-}" ]] && echo "${COTYPE_UPDATE_FEED_URL}" || echo 'none (not a release candidate)')"
  echo "  sparkle pub key   : $([[ "$NOTARIZED" == "1" && -n "${COTYPE_UPDATE_PUBLIC_KEY:-}" ]] && echo present || echo none)"
  echo "  architecture      : $(lipo -info "$ROOT/.build/release/$COTYPE_PRODUCT" 2>/dev/null | sed -n 's/.*: //p' || echo 'unknown')"
  echo "  llama framework   : $LLAMA_FRAMEWORK"
  echo "  sparkle framework : $SPARKLE_FRAMEWORK"
  exit 0
fi

# ---------------------------------------------------------------------------
# Assemble the bundle. (The product and required frameworks are already built and
# resolved above, on both the --info and the build path.)
# ---------------------------------------------------------------------------
APP="$COTYPE_DIST_APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$COTYPE_APP_NAME"
mkdir -p "$APP/Contents/Frameworks"
ditto "$LLAMA_FRAMEWORK" "$APP/Contents/Frameworks/llama.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

# Icon. The house icon family is rendered by design-system/icons/make-icon.py
# (`--glyph cotype`); Assets/AppIcon.icns is that render and is preferred
# verbatim. Assets/AppIcon.png is the same master and is the fallback path for a
# tree that has not been re-rendered yet.
ICONSET="$COTYPE_DIST/$COTYPE_APP_NAME.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
if [[ -f "$ROOT/Assets/AppIcon.icns" ]]; then
  cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/$COTYPE_APP_NAME.icns"
elif [[ -f "$ROOT/Assets/AppIcon.png" ]]; then
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$COTYPE_APP_NAME.icns"
fi
rm -rf "$ICONSET"

# ---------------------------------------------------------------------------
# Version-stamped Info.plist (including Sparkle update config for a release
# candidate only, with XML value escaping so '&' etc. cannot break the plist).
# ---------------------------------------------------------------------------
# Embed the Sparkle update config only when it is explicitly requested: a
# release candidate (--notarize, which requires it and is validated below) OR an
# explicit test override (COTYPE_EMBED_UPDATE_CONFIG=1) that the generate-appcast
# self-test uses to build an app carrying the matching public key. A plain dev
# build emits neither key, so the updater stays inert.
FEED_PLIST=""
if [[ "$NOTARIZED" == "1" || "${COTYPE_EMBED_UPDATE_CONFIG:-0}" == "1" ]]; then
  if [[ -n "${COTYPE_UPDATE_FEED_URL:-}" ]]; then
    # SUFeedURL is the Sparkle appcast URL. Convention: it lives at
    # Cotype-<version>/appcast.xml beneath the channel base URL, so append the
    # well-known filename (normalizing any trailing slash).
    APPCAST_URL="${COTYPE_UPDATE_FEED_URL%/}/appcast.xml"
    FEED_PLIST+="    <key>SUFeedURL</key><string>$(xml_escape "$APPCAST_URL")</string>"$'\n'
  fi
  if [[ -n "${COTYPE_UPDATE_PUBLIC_KEY:-}" ]]; then
    FEED_PLIST+="    <key>SUPublicEDKey</key><string>$(xml_escape "$COTYPE_UPDATE_PUBLIC_KEY")</string>"$'\n'
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$COTYPE_APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$COTYPE_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$COTYPE_APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$COTYPE_DISPLAY_NAME</string>
    <key>CFBundleIconFile</key><string>$COTYPE_APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$COTYPE_VERSION</string>
    <key>CFBundleVersion</key><string>$COTYPE_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAccessibilityUsageDescription</key><string>Cotype reads text around the cursor and inserts completions you accept. All inference is local.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026. All rights reserved. See the repository for third-party licenses and the privacy notice.</string>

    <!-- Build metadata -->
    <key>CotypeBuildMode</key><string>$mode</string>
    <key>CotypeBuildGitCommit</key><string>$COTYPE_GIT_COMMIT</string>
    <key>CotypeBuildGitCommitLong</key><string>$COTYPE_GIT_COMMIT_LONG</string>
    <key>CotypeBuildGitDirty</key><string>$COTYPE_GIT_DIRTY</string>
    <key>CotypeBuildDate</key><string>$COTYPE_BUILD_DATE</string>
    <key>CotypeBundleID</key><string>$COTYPE_BUNDLE_ID</string>
    <key>CotypeLlamaBuild</key><string>$COTYPE_LLAMA_BUILD</string>
    <key>CotypeLlamaVersion</key><string>$COTYPE_LLAMA_VERSION</string>
    <key>CotypeLlamaLicense</key><string>$COTYPE_LLAMA_LICENSE</string>
    <key>CotypeModelFilename</key><string>$COTYPE_MODEL_FILENAME</string>
    <key>CotypeModelLicense</key><string>$COTYPE_MODEL_LICENSE</string>
    <key>CotypeModelLicenseURL</key><string>$COTYPE_MODEL_LICENSE_URL</string>
    <key>CotypeSigningIdentity</key><string>$(sign_identity_label "$SIGN_IDENTITY")</string>
    <key>CotypeArchitecture</key><string>arm64</string>
    <key>CotypeNotarized</key><false/>
    <key>CotypeReleaseCandidate</key><$([[ "$NOTARIZED" == "1" ]] && echo true || echo false)/>
$FEED_PLIST</dict>
</plist>
PLIST

# For a release candidate, confirm the Sparkle update config actually made it into
# the plist (a silently-missing SUFeedURL/SUPublicEDKey would ship a broken
# updater). Dev builds never require these keys.
if [[ "$NOTARIZED" == "1" ]]; then
  if ! plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    die "Info.plist failed lint for the release candidate."
  fi
  if ! plutil -p "$APP/Contents/Info.plist" | grep -q '"SUFeedURL"'; then
    die "SUFeedURL was not written to Info.plist for the release candidate."
  fi
  if ! plutil -p "$APP/Contents/Info.plist" | grep -q '"SUPublicEDKey"'; then
    die "SUPublicEDKey was not written to Info.plist for the release candidate."
  fi
fi

# ---------------------------------------------------------------------------
# Embed licenses/notices into Resources so they ship with the app.
# ---------------------------------------------------------------------------
LICENSE_DIR="$ROOT/docs/licenses"
if [[ -d "$LICENSE_DIR" ]]; then
  cp "$LICENSE_DIR"/* "$APP/Contents/Resources/" 2>/dev/null || true
fi
[[ -f "$ROOT/PRIVACY.md" ]] && cp "$ROOT/PRIVACY.md" "$APP/Contents/Resources/Cotype-Privacy.md"

# ---------------------------------------------------------------------------
# rpath so the embedded llama.framework resolves.
# ---------------------------------------------------------------------------
if ! otool -l "$APP/Contents/MacOS/$COTYPE_APP_NAME" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/$COTYPE_APP_NAME"
fi

# ---------------------------------------------------------------------------
# Codesign (framework first, then the app), then verify.
# ---------------------------------------------------------------------------
log "Signing with '$SIGN_IDENTITY' ($(sign_identity_label "$SIGN_IDENTITY"))"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# Sign the embedded frameworks. Sparkle ships its own helper (Updater.app) and
# XPC services inside the framework, so those are signed first, then the
# framework, then the app — the order Sparkle requires for a proper signature
# chain.
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/llama.framework"
SPARKLE_BUNDLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
if [[ -d "$SPARKLE_BUNDLE/Updater.app" ]]; then
  codesign "${SIGN_ARGS[@]}" "$SPARKLE_BUNDLE/Updater.app"
fi
if [[ -d "$SPARKLE_BUNDLE/XPCServices" ]]; then
  find "$SPARKLE_BUNDLE/XPCServices" -maxdepth 1 -name '*.xpc' -type d | while read -r xpc; do
    codesign "${SIGN_ARGS[@]}" "$xpc"
  done
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP"
record_sign_identity "$SIGN_IDENTITY"

log "Verifying bundle…"
verify_bundle "$APP"

# The app redistributes Sparkle.framework; its license must travel with it or the
# release is not compliant. The license is copied from docs/licenses together
# with the other notices.
if [[ ! -f "$APP/Contents/Resources/SPARKLE-LICENSE.txt" ]]; then
  die "Sparkle license is missing from the bundle (SPARKLE-LICENSE.txt). Ensure docs/licenses/SPARKLE-LICENSE.txt exists and rebuild."
fi
log "Bundle includes Sparkle license (SPARKLE-LICENSE.txt)."

log "Built $APP"
if [[ "$NOTARIZED" == "1" ]]; then
  log "Built a Developer ID RELEASE CANDIDATE (not yet notarized). Run scripts/notarize.sh to notarize, staple, and verify before release."
elif [[ "${mode:-}" != "development" ]]; then
  log "NOT notarized. Personal build only — see docs/RELEASE.md for the opt-in release path."
fi
