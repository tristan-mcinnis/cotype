#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Cotype diagnostic report. Produces a safe-to-share report of version, build
# metadata, signing, model (path/size/hash), llama.cpp build, and permission
# PREFLIGHT status. It never reads document text, clipboard contents, or the
# personalization / app-overrides data files.
#
#   ./scripts/diagnostics.sh                 text report to stdout
#   ./scripts/diagnostics.sh --format json   machine-readable report
#   ./scripts/diagnostics.sh --hash          include the model SHA-256
#   ./scripts/diagnostics.sh --app <path>    target a specific Cotype.app
#   ./scripts/diagnostics.sh --out <file>    write the report to a file
#
# The actual API calls (AXIsProcessTrusted / CGPreflight*) live in the
# cotype-diagnostics Swift executable, which is built on demand.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

APP="${COTYPE_APP:-$COTYPE_APP}"
OUT=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --hash|--no-hash) EXTRA+=("$1"); shift ;;
    --format) EXTRA+=("--format" "$2"); shift 2 ;;
    --help|-h) echo "Usage: ./scripts/diagnostics.sh [--app path] [--format json|text] [--hash|--no-hash] [--out file]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# Ask SwiftPM to build every time. It is incremental when current, and avoids
# silently reporting stale model-path or permission logic after source changes.
log "Building diagnostics tool…" >&2
swift build -c release --product cotype-diagnostics >/dev/null

# Canonical installed-app path when none supplied.
if [[ "$APP" == "$COTYPE_APP" ]] && [[ ! -d "$APP" ]]; then
  APP="$COTYPE_DIST_APP"
fi

set +e
OUTPUT="$("$ROOT/.build/release/cotype-diagnostics" \
  --app "$APP" \
  --llama-build "$COTYPE_LLAMA_BUILD" \
  "${EXTRA[@]+${EXTRA[@]}}")"
code=$?
set -e
if [[ "$code" != "0" ]]; then
  die "Diagnostics tool failed (exit $code)."
fi

if [[ -n "$OUT" ]]; then
  printf '%s\n' "$OUTPUT" > "$OUT"
  log "Report written to $OUT"
else
  printf '%s\n' "$OUTPUT"
fi
