#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Cotype install / reinstall / uninstall.
#
#   ./scripts/install.sh              build, quit running Cotype, install, relaunch, verify
#   ./scripts/install.sh reinstall    alias for the default (robust, idempotent)
#   ./scripts/install.sh uninstall    stop + remove the app (leaves settings/model)
#   ./scripts/install.sh repair       rebuild + reinstall + verify (keeps model/settings)
#
# Options:
#   --with-in-process-model  provision a private Cotype model copy (legacy fallback)
#   --require-model          provision it and fail if the source model is absent
#   --skip-model             explicit default: use the Local Models daemon only
#   --no-build               use the existing dist/Cotype.app (must already exist)
#   --no-relaunch      install but do not open the app afterwards
#   --dir <path>       install directory (overrides COTYPE_INSTALL_DIR)
#
# Safety: this quits any running Cotype (graceful -> SIGTERM -> SIGKILL) before
# replacing the bundle, then relaunches. It verifies codesign / rpath / plist and
# reports permission preflight status READ-ONLY. It never grants or bypasses
# macOS TCC.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

CMD="install"
# Local Models owns ~/Models, the registry, and loaded weights. Cotype installs
# as a thin daemon client by default and does not duplicate a multi-GB model.
SKIP_MODEL=1
REQUIRE_MODEL=0
DO_BUILD=1
DO_RELAUNCH=1

usage() { sed -n '2,16p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|reinstall|repair) CMD="$1"; shift ;;
    uninstall) CMD="uninstall"; shift ;;
    --skip-model) SKIP_MODEL=1; REQUIRE_MODEL=0; shift ;;
    --with-in-process-model) SKIP_MODEL=0; shift ;;
    --require-model) SKIP_MODEL=0; REQUIRE_MODEL=1; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --no-relaunch) DO_RELAUNCH=0; shift ;;
    --dir) COTYPE_INSTALL_DIR="$2"; COTYPE_APP="$COTYPE_INSTALL_DIR/$COTYPE_APP_NAME.app"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) die "Unexpected argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "$CMD" == "uninstall" ]]; then
  if [[ -d "$COTYPE_APP" ]]; then
    quit_cotype "$COTYPE_APP"
    rm -rf "$COTYPE_APP"
    log "Removed $COTYPE_APP"
    log "Settings and model were left intact at $COTYPE_MODEL_DIR"
  else
    log "Nothing to uninstall at $COTYPE_APP"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Build (unless --no-build)
# ---------------------------------------------------------------------------
if [[ "$DO_BUILD" == "1" ]]; then
  log "Building app bundle…"
  "$ROOT/scripts/build-app.sh"
else
  [[ -d "$COTYPE_DIST_APP" ]] || die "--no-build requested but no bundle at $COTYPE_DIST_APP (run ./scripts/build-app.sh)."
  log "Using existing bundle at $COTYPE_DIST_APP"
fi

# ---------------------------------------------------------------------------
# Model provision
# ---------------------------------------------------------------------------
if [[ "$SKIP_MODEL" == "1" ]]; then
  log "Using the Local Models daemon; no private Cotype model copy will be installed."
else
  mkdir -p "$COTYPE_MODEL_DIR" "$COTYPE_INSTALL_DIR"
  if model_exists "$COTYPE_MODEL_SOURCE"; then
    if model_is_valid "$COTYPE_MODEL_SOURCE"; then
      if model_exists "$COTYPE_MODEL" && model_is_valid "$COTYPE_MODEL"; then
        log "Model already present and verified at $COTYPE_MODEL"
      else
        log "Copying model into Cotype's model directory…"
        MODEL_TEMP="$COTYPE_MODEL.tmp.$$"
        trap 'rm -f "${MODEL_TEMP:-}"' EXIT
        cp "$COTYPE_MODEL_SOURCE" "$MODEL_TEMP"
        model_is_valid "$MODEL_TEMP" || die "Copied model failed checksum verification; existing model was left untouched."
        mv -f "$MODEL_TEMP" "$COTYPE_MODEL"
        trap - EXIT
      fi
      log "Model verified (SHA-256 matches)."
    else
      die "Model checksum mismatch at $COTYPE_MODEL_SOURCE (expected $COTYPE_MODEL_SHA256)."
    fi
  else
    if [[ "$REQUIRE_MODEL" == "1" ]]; then
      die "Required model not found at $COTYPE_MODEL_SOURCE."
    fi
    warn "No model at $COTYPE_MODEL_SOURCE — installing the app only."
    warn "Place the model there (or download it in-app once the downloader is wired) to use completions."
  fi
fi

# ---------------------------------------------------------------------------
# Stage and verify the replacement before stopping the running app. Then swap
# bundles on the same volume, retaining a rollback copy until verification.
# ---------------------------------------------------------------------------
mkdir -p "$COTYPE_INSTALL_DIR"
STAGED_APP="$COTYPE_INSTALL_DIR/.Cotype.installing.$$"
BACKUP_APP="$COTYPE_INSTALL_DIR/.Cotype.backup.$$"
cleanup_install() { rm -rf "$STAGED_APP" "$BACKUP_APP"; }
trap cleanup_install EXIT
rm -rf "$STAGED_APP" "$BACKUP_APP"
ditto "$COTYPE_DIST_APP" "$STAGED_APP"
log "Verifying staged app…"
verify_bundle "$STAGED_APP"

if [[ -d "$COTYPE_APP" ]]; then
  log "Existing app found — stopping it before replacement."
  quit_cotype "$COTYPE_APP"
  mv "$COTYPE_APP" "$BACKUP_APP"
else
  log "No existing app at $COTYPE_APP."
fi

if ! mv "$STAGED_APP" "$COTYPE_APP"; then
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$COTYPE_APP"
  die "Could not install replacement; the previous app was restored."
fi

# ---------------------------------------------------------------------------
# Post-install verification (structure + signature, read-only permission report).
# ---------------------------------------------------------------------------
log "Verifying installed app…"
if ! verify_bundle "$COTYPE_APP"; then
  rm -rf "$COTYPE_APP"
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$COTYPE_APP"
  die "Installed bundle failed verification; the previous app was restored."
fi
rm -rf "$BACKUP_APP"
trap - EXIT
log "Installed to $COTYPE_APP"

log "Permission preflight (read-only; Cotype never grants these on install):"
# We only *report* preflight status through the app's own diagnostics tool,
# which reads AXIsProcessTrusted / CGPreflight* — see scripts/diagnostics.sh.
# It is best-effort here so install still succeeds if the tool is unavailable.
if ! "$ROOT/scripts/diagnostics.sh" --app "$COTYPE_APP" --format text --no-hash >/dev/null 2>&1; then
  warn "Could not run diagnostics for permission preflight (continue; use './scripts/diagnostics.sh')."
fi

# ---------------------------------------------------------------------------
# Relaunch.
# ---------------------------------------------------------------------------
if [[ "$DO_RELAUNCH" == "1" ]]; then
  log "Launching $COTYPE_APP …"
  open "$COTYPE_APP"
  log "Installed and opened $COTYPE_APP"
else
  log "Installed $COTYPE_APP (--no-relaunch)."
fi

log "Done. Models are managed by the Local Models menu bar. Use \`--with-in-process-model\` only for the legacy standalone fallback."
