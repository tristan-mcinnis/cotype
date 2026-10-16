#!/bin/sh
# Publish scrub: no user-specific paths, personal addresses or key material in tracked files.
#
# Generic patterns live here. Private tokens (client and employer names,
# personal addresses, hostnames) belong in .scrub-private (gitignored, one ERE
# per line) so the scanner never publishes what it scans for. This file is the
# one tracked file excluded from the scan, so review it by hand.
set -e
cd "$(dirname "$0")/.."

GENERIC='/Users/[a-z]+/|~/vault|~/memory|vault-vps|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-|hf_[A-Za-z0-9]{30,}|ghp_[A-Za-z0-9]{30,}'
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
PATTERN="$GENERIC"
if [ -f .scrub-private ]; then
  PRIVATE=$(grep -vE '^[[:space:]]*(#|$)' .scrub-private | paste -sd'|' -)
  [ -n "$PRIVATE" ] && PATTERN="$GENERIC|$PRIVATE"
fi

control=$(mktemp)
printf '/Users/nobody/leak\n' > "$control"
if ! grep -qE "$PATTERN" "$control"; then
  echo "SCRUB_SELFTEST_FAILED"; rm -f "$control"; exit 1
fi
rm -f "$control"

hits=$(git ls-files -z | grep -zv '^scripts/scrub\.sh$' | xargs -0 grep -IlE "$PATTERN" 2>/dev/null || true)

mail=$(git ls-files -z | grep -zv '^scripts/scrub\.sh$' | xargs -0 grep -IoE "$EMAIL" 2>/dev/null \
  | grep -viE '@(example\.(com|org|net)|noreply\.github\.com|users\.noreply\.github\.com|anthropic\.com)$' \
  | grep -viE '^docs/licenses/[^:]*:' || true)

if [ -n "$hits" ] || [ -n "$mail" ]; then
  echo "PRIVATE CONTENT FOUND:"
  [ -n "$hits" ] && echo "$hits"
  [ -n "$mail" ] && echo "$mail"
  exit 1
fi
echo "SCRUB_CLEAN"
