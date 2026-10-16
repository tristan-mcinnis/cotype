#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Validate the structure + signature of a Cotype.app bundle. Used by CI and by
# ./scripts/verify.sh. Gatekeeper assessment is informational only, because a
# personal build is not notarized (expected). Hard failures (missing binary,
# invalid plist, missing rpath, broken signature) exit non-zero.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

APP="${1:-$COTYPE_DIST_APP}"

log "Verifying bundle: $APP"
if verify_bundle "$APP"; then
  log "Bundle verification passed."
  exit 0
fi
exit 1
