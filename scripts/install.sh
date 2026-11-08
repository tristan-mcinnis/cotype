#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Cotype install / reinstall / uninstall.
#
#   ./scripts/install.sh              build, quit running Cotype, install, relaunch, verify
#   ./scripts/install.sh reinstall    alias for the default (robust, idempotent)
#   ./scripts/install.sh uninstall    stop + remove the app (leaves settings)
#   ./scripts/install.sh repair       rebuild + reinstall + verify (keeps settings)
#
# Options:
#   --no-build         use the existing dist/Cotype.app (must already exist)
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
DO_BUILD=1
DO_RELAUNCH=1

usage() { sed -n '2,13p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|reinstall|repair) CMD="$1"; shift ;;
    uninstall) CMD="uninstall"; shift ;;
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
    log "Settings were left intact."
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
if ! "$ROOT/scripts/diagnostics.sh" --app "$COTYPE_APP" --format text >/dev/null 2>&1; then
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

log "Done. Models are managed by the Local Models menu bar."
