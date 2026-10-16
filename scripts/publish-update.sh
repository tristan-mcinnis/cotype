#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Publish a Cotype update channel release SAFELY. This is the release-side
# publish contract. The app's Sparkle updater fetches SUFeedURL, so publishing is
# the one action that turns a local build into a live update.
#
# By default this script only VALIDATES and prints a SAFE UPLOAD PLAN — it will
# NOT touch the channel. Publishing requires BOTH --publish AND --command (an
# explicit operator/CI approval). CI therefore never publishes on an ordinary
# build; it must be a deliberate, gated workflow input.
#
# The plan is derived from the exact CURRENT artifacts declared in the generated
# update-manifest.json (the release contract; or, if that is absent, from
# appcast.xml enclosure URLs) — never from a `Cotype-*` glob, so a reused release
# dir holding an old archive is not uploaded as the "current" update. Old archives
# are retained, never deleted. NOTE: this script validates each artifact's sha256
# but does NOT itself verify the manifest's Ed25519 signature (that is the
# publish/CI gate's responsibility); we do not claim cryptographic verification here.
#
#   ./scripts/publish-update.sh --dry-run --channel-url https://updates.example.com/cotype dist/release
#   ./scripts/publish-update.sh --publish --command 'scp "$FILE" host:updates/cotype/$NAME' \
#       --channel-url https://updates.example.com/cotype dist/release
#   ./scripts/publish-update.sh --self-test
#
# Options:
#   --self-test          Deterministic validation checks; never publishes.
#   --dry-run            Validate + print the safe upload plan; never publishes.
#   --publish            Actually publish (requires --command).
#   --command <cmd>      Shell command run once per file with FILE/NAME/URL env set.
#   --channel-url <url>  Base URL the appcast URLs must resolve under; required for
#                        release publish so URLs are absolute and verified.
#
# SAFE PUBLISH ORDER (archive FIRST, appcast LAST):
#   1. update archive(s) declared by the current manifest/appcast
#   2. release notes / manifest (optional)
#   3. appcast.xml  LAST — this is the switch that makes the update live.
#
# This is safe ORDERING, not atomicity. If step 3 fails, the channel still serves the
# OLD appcast (no partial update is advertised); re-run to complete. To make appcast
# replacement truly atomic (no window in which a partial appcast is served), the
# --command backend MUST upload to a temp path and then server-side rename into the
# final appcast path. This script never makes uploads atomic — atomicity is only as
# good as the backend — and it documents the contract rather than claiming it. Old
# archives are retained; rollback = re-publish the previous appcast.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

RELEASE_DIR="${COTYPE_RELEASE_DIR:-$COTYPE_DIST/release}"
CHANNEL_URL="${COTYPE_CHANNEL_URL:-}"
COMMAND="${COTYPE_PUBLISH_COMMAND:-}"
PUBLISH=0
DRY_RUN=0
SELF_TEST=0

usage() { sed -n '2,30p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --command) COMMAND="$2"; shift 2 ;;
    --channel-url) CHANNEL_URL="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) RELEASE_DIR="$1"; shift ;;
  esac
done

# The deterministic self-test is defined below (after the helper functions it
# calls) and invoked by the `--self-test` branch in the main flow.

# ---------------------------------------------------------------------------
# Deterministically derive the exact current artifact filenames to publish from
# the generated update-manifest.json (the release contract — its Ed25519 signature
# is NOT verified here) or, failing that, from the appcast.xml enclosure URLs.
# Rejects ambiguity, missing files, checksum mismatch, and path traversal. Never
# uses a glob over old archives.
# Prints one "<filename>\t<sha256>" line per artifact, in manifest/appcast order.
# ---------------------------------------------------------------------------
current_artifact_filenames() {
  local dir="$1"
  python3 - "$dir" <<'PY'
import json, os, sys, hashlib
import xml.etree.ElementTree as ET
release = sys.argv[1]
manifest = os.path.join(release, "update-manifest.json")
appcast = os.path.join(release, "appcast.xml")

def valid_name(n):
    if not n: return False
    if n != os.path.basename(n): return False      # no path separators / traversal
    if "/" in n or "\\" in n or ".." in n: return False
    return True

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

files = []
if os.path.exists(manifest):
    data = json.load(open(manifest))
    arts = data.get("artifacts", [])
    if not arts:
        print("error: manifest declares no artifacts", file=sys.stderr); sys.exit(1)
    for a in arts:
        n = a.get("filename", "")
        if not valid_name(n):
            print("error: manifest artifact filename invalid (%r)" % n, file=sys.stderr); sys.exit(1)
        p = os.path.join(release, n)
        if not os.path.exists(p):
            print("error: manifest artifact missing: %s" % n, file=sys.stderr); sys.exit(1)
        expect = a.get("sha256", "")
        if expect and sha256(p) != expect:
            print("error: sha256 mismatch for %s" % n, file=sys.stderr); sys.exit(1)
        files.append((n, expect))
else:
    if not os.path.exists(appcast):
        print("error: neither update-manifest.json nor appcast.xml present", file=sys.stderr); sys.exit(1)
    root = ET.parse(appcast).getroot()
    seen = set()
    for encl in root.iter("enclosure"):
        u = encl.get("url", "")
        n = u.rsplit("/", 1)[-1]
        if not valid_name(n):
            print("error: appcast enclosure filename invalid (%r)" % u, file=sys.stderr); sys.exit(1)
        if n in seen: continue
        seen.add(n)
        p = os.path.join(release, n)
        if not os.path.exists(p):
            print("error: appcast archive missing: %s" % n, file=sys.stderr); sys.exit(1)
        files.append((n, ""))

names = [n for n, _ in files]
if len(set(names)) != len(names):
    print("error: ambiguous/duplicate artifact filenames", file=sys.stderr); sys.exit(1)
for n, s in files:
    print("%s\t%s" % (n, s))
PY
}

# Build the ordered publish plan. Emits the plan as a list of absolute file paths
# (archive(s) first, appcast LAST). Dies on any validation failure.
build_publish_plan() {
  local dir="$1" base="$2"
  local zip_from_manifest=0
  local files_with_sha
  files_with_sha="$(current_artifact_filenames "$dir")" || return 1
  local plan=()
  while IFS=$'\t' read -r NAME SHA; do
    [[ -n "$NAME" ]] || continue
    plan+=("$dir/$NAME")
  done <<< "$files_with_sha"
  # Notes + manifest (optional) before appcast.
  for extra in "$dir"/release-notes-*.txt "$dir"/update-manifest.json; do
    [[ -f "$extra" ]] && plan+=("$extra")
  done
  plan+=("$dir/appcast.xml")
  # Emit ABSOLUTE paths: these are the FILE values the upload loop executes, so a
  # release dir outside the current working directory (or a reused cwd) must not
  # cause a mis-resolved path. Display code uses basename separately.
  printf '%s\n' "${plan[@]}"
}

# ---------------------------------------------------------------------------
# Self-test (deterministic; no real release dir / channel). Proves the exact
# artifact selection: a stale earlier archive in the dir is NEVER chosen when the
# current manifest/appcast names a different (current) archive.
# ---------------------------------------------------------------------------
__publish_self_test() {
  local failures=0 tmp SHA_CURRENT
  chk() { "$@" || { echo "  FAIL: $*"; failures=$((failures + 1)); }; }
  echo "publish-update self-test"

  # URL resolution.
  url_for() {
    local base="$1" name="$2"
    if [[ "$name" =~ ^https?:// ]]; then printf '%s' "$name"; else printf '%s%s' "${base%/}/" "$name"; fi
  }
  chk test "$(url_for "https://u.example.com/cotype" "appcast.xml")" = "https://u.example.com/cotype/appcast.xml"

  tmp="$(mktemp -d -t cotype-publish-stale.XXXXXX)"
  # Stale archive from an older release + the CURRENT one. Manifest names only the
  # current version, so publish must plan ONLY the current archive (never the stale
  # lexicographically-first one).
  printf 'stale' > "$tmp/Cotype-0.0.0.zip"        # lexicographically earlier than 0.1.0
  printf 'current' > "$tmp/Cotype-0.1.0.zip"
  # The plan always appends appcast.xml; provide a stub so existence assertions hold.
  printf '<rss></rss>' > "$tmp/appcast.xml"
  SHA_CURRENT="$(shasum -a 256 "$tmp/Cotype-0.1.0.zip" | awk '{print $1}')"
  cat > "$tmp/update-manifest.json" <<JSON
{"schemaVersion":1,"version":"0.1.0","buildNumber":"120","artifacts":[
  {"filename":"Cotype-0.1.0.zip","kind":"zip","size":7,"sha256":"$SHA_CURRENT","url":"https://updates.example.com/cotype/Cotype-0.1.0.zip"}]}
JSON
  # plan_for runs the plan-builder and emits ABSOLUTE path(s), in order.
  plan_for() { build_publish_plan "$1" "$2" ; }

  # 1) Stale archive must NOT be planned; only the manifest's Cotype-0.1.0.zip
  #    (compared by basename), and the planned FILE path must be an absolute,
  #    existing path UNDER the release dir (which here is outside the cwd).
  chk test "$(basename "$(plan_for "$tmp" "https://updates.example.com/cotype" | head -1)")" = "Cotype-0.1.0.zip"
  # Every planned executable path must be absolute, under the release dir, and exist.
  for f in $(plan_for "$tmp" "https://updates.example.com/cotype"); do
    chk test "$f" = "$tmp/$(basename "$f")"       # path is exactly under the release dir (absolute, no rebasing)
    chk test -f "$f"                               # file exists
  done
  # 2) A manifest naming an archive that is not present must be rejected (mismatch).
  cat > "$tmp/update-manifest.json" <<'JSON'
{"schemaVersion":1,"version":"0.9.9","buildNumber":"119","artifacts":[
  {"filename":"Cotype-0.9.9.zip","kind":"zip","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","url":"https://updates.example.com/cotype/Cotype-0.9.9.zip"}]}
JSON
  if ( plan_for "$tmp" "https://updates.example.com/cotype" >/dev/null 2>&1 ); then
    echo "  FAIL: missing current archive was not rejected"; failures=$((failures + 1))
  fi
  # 3) Path traversal / non-basename filename must be rejected.
  cat > "$tmp/update-manifest.json" <<'JSON'
{"schemaVersion":1,"version":"0.1.0","buildNumber":"120","artifacts":[
  {"filename":"../evil.zip","kind":"zip","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","url":"https://updates.example.com/cotype/evil.zip"}]}
JSON
  if ( plan_for "$tmp" "https://updates.example.com/cotype" >/dev/null 2>&1 ); then
    echo "  FAIL: path-traversal filename was not rejected"; failures=$((failures + 1))
  fi

  rm -rf "$tmp"
  if [[ "$failures" -ne 0 ]]; then die "publish-update self-test failed ($failures)."; fi
  echo "publish-update self-test: passed (exact current artifact chosen; stale/missing/traversal rejected)"
}

# ---------------------------------------------------------------------------
# Self-test entry point.
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
  __publish_self_test
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate the release dir, derive the exact current plan, and validate URLs.
# ---------------------------------------------------------------------------
[[ -d "$RELEASE_DIR" ]] || die "Release dir not found: $RELEASE_DIR"
[[ -n "$CHANNEL_URL" ]] || die "--channel-url is required (appcast URLs must be absolute; got none)."
APPCAST="$RELEASE_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || die "No appcast.xml in $RELEASE_DIR (run scripts/generate-appcast.sh first)."

# Validate the appcast with an XML parser: every enclosure signed, absolute https,
# SAME origin as the channel base, path under the base at a '/' boundary.
python3 - "$APPCAST" "$CHANNEL_URL" <<'PY'
import sys
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
appcast, base = sys.argv[1], sys.argv[2]
base_u = urlparse(base if "://" in base else "https://" + base)
if base_u.scheme != "https":
    print("error: channel base must be https", file=sys.stderr); sys.exit(1)
base_path = base_u.path.rstrip("/") + "/"
ED_SIG = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
root = ET.parse(appcast).getroot()
cnt = 0
for encl in root.iter("enclosure"):
    cnt += 1
    if ED_SIG not in encl.attrib:
        print("error: enclosure missing sparkle:edSignature", file=sys.stderr); sys.exit(1)
    u = urlparse(encl.attrib.get("url", ""))
    if u.scheme != "https" or not u.netloc:
        print("error: enclosure url not absolute https: %s" % encl.attrib.get("url"), file=sys.stderr); sys.exit(1)
    if (u.scheme, u.netloc) != (base_u.scheme, base_u.netloc):
        print("error: enclosure url different origin: %s vs %s" % (u.netloc, base_u.netloc), file=sys.stderr); sys.exit(1)
    if base_path and not (u.path == base_path.rstrip("/") or u.path.startswith(base_path)):
        print("error: enclosure url path %s not under %s" % (u.path, base_path), file=sys.stderr); sys.exit(1)
if cnt == 0:
    print("error: no enclosures in appcast", file=sys.stderr); sys.exit(1)
print("ok: %d signed enclosures, https, same origin, path under %s" % (cnt, base_path))
PY

# Derive the exact current plan (dies on stale/ambiguous/missing/mismatch/traversal).
PLAN_NAMES="$(build_publish_plan "$RELEASE_DIR" "$CHANNEL_URL")" || die "Could not build a valid publish plan for $RELEASE_DIR."
# bash 3.2 (macOS) has no mapfile; read line-by-line into an array.
PLAN=()
while IFS= read -r f; do
  [[ -n "$f" ]] && PLAN+=("$f")
done <<< "$PLAN_NAMES"
[[ "${#PLAN[@]}" -gt 0 ]] || die "Publish plan is empty."

rel_name() { printf '%s' "$(basename "$1")"; }
url_for() {
  local base="$1" name="$2"
  if [[ "$name" =~ ^https?:// ]]; then printf '%s' "$name"; else printf '%s%s' "${base%/}/" "$name"; fi
}

echo "publish-update plan (SAFE PUBLISH ORDER; archive first, appcast LAST):"
n=0
for f in "${PLAN[@]}"; do
  n=$((n + 1))
  echo "  $n. $(url_for "$CHANNEL_URL" "$(rel_name "$f")")  <- $(basename "$f")"
done
echo "Channel is NOT live until appcast.xml uploads. Old archives are retained; the"
echo "feed points at prior items, so a failed appcast upload leaves the old feed live."
echo "For truly atomic appcast replacement, the backend must upload to a temp path then"
echo "server-side rename; this script only guarantees safe ORDER (archive before appcast)."

if [[ "$PUBLISH" != "1" ]]; then
  [[ "$DRY_RUN" == "1" ]] && log "DRY-RUN: no files were published; the update channel was NOT changed."
  log "Channel status: NOT LIVE (dry-run / plan only). Pass --publish --command <cmd> to publish."
  exit 0
fi

[[ -n "$COMMAND" ]] || die "--publish requires --command <cmd> (the upload backend)."

log "Publishing updates in safe order (archive first, appcast LAST)…"
for f in "${PLAN[@]}"; do
  NAME="$(rel_name "$f")"
  URL="$(url_for "$CHANNEL_URL" "$NAME")"
  log "Uploading $NAME -> $URL"
  FILE="$f" NAME="$NAME" URL="$URL" bash -c "$COMMAND"
done
log "Published. appcast.xml was uploaded last, so the channel is now live."
