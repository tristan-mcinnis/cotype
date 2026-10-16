#!/usr/bin/env bash
# shellcheck shell=bash
set -uo pipefail

# Cotype acceptance run (2026-09-25). Re-runnable by anyone on this Mac.
#
#   T1  swift build + swift test pass (prints the test count)
#   T2  real-model quality gate, UNCHANGED thresholds (>=90% valid, 0 forbidden)
#   T3  end-to-end pipeline test: typed text -> suggestion -> ghost -> accept ->
#       inserted text in an in-process NSTextView, >=20 cases incl. word boundaries
#   T4  installed app is the HEAD build (commit stamp, clean tree, same binary),
#       the process runs, and it is still the same process 60 s after launch
#   T5  median suggestion latency from a warm model, production engine path
#       (target < 400 ms)
#   T6  manual checklist exists (docs/acceptance-20260925.md); the maintainer runs it
#
# It never types into, clicks, or focuses another app. T4 launches Cotype in
# the background (`open -g`) only if it is not already running. T5 asks Local
# Models to warm `gemma-it` (the same request Cotype itself makes).
#
# Usage: ./scripts/acceptance.sh [--skip-gate] [--skip-install-check]
# Exit: 0 when T1-T5 all pass, 1 otherwise. T6 is manual and never fails the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/shared.sh
source "$ROOT/scripts/shared.sh"
# shared.sh turns on errexit; every test here must run and report on its own.
set +e
cd "$ROOT" || exit 1

SKIP_GATE=0
SKIP_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --skip-gate) SKIP_GATE=1 ;;
    --skip-install-check) SKIP_INSTALL=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

OUT="$(mktemp -d "${TMPDIR:-/tmp}/cotype-acceptance.XXXXXX")"
declare -a RESULTS=()
FAILED=0
record() { # id status detail
  RESULTS+=("$(printf '%-3s %-6s %s' "$1" "$2" "$3")")
  [[ "$2" == "FAIL" ]] && FAILED=1
  printf '\n>>> %s %s: %s\n' "$1" "$2" "$3"
}

# --------------------------------------------------------------------------
echo "== T1: swift build + swift test"
if swift build >"$OUT/build.log" 2>&1 && swift test >"$OUT/test.log" 2>&1; then
  line="$(grep -E 'Executed [0-9]+ tests' "$OUT/test.log" | tail -1 | sed 's/^[[:space:]]*//')"
  record T1 PASS "${line:-tests passed}"
else
  line="$(grep -E 'Executed [0-9]+ tests|error:' "$OUT/test.log" "$OUT/build.log" 2>/dev/null | tail -3 | tr '\n' ' ')"
  record T1 FAIL "build or tests failed: $line (logs: $OUT)"
fi

# --------------------------------------------------------------------------
echo "== T2: real-model quality gate (unchanged thresholds)"
if [[ "$SKIP_GATE" == "1" ]]; then
  record T2 SKIP "skipped by flag"
elif ! model_exists "$COTYPE_MODEL_SOURCE"; then
  record T2 FAIL "model missing at $COTYPE_MODEL_SOURCE"
else
  swift run cotype-eval --engine llama --model "$COTYPE_MODEL_SOURCE" --max-tokens 32 \
    --model-repo "$COTYPE_MODEL_REPO" --model-revision "$COTYPE_MODEL_REVISION" \
    --model-sha "$COTYPE_MODEL_SHA256" >"$OUT/gate.log" 2>&1
  code=$?
  valid="$(grep -E '^valid rate:' "$OUT/gate.log" | awk '{print $3}')"
  forbidden="$(grep -E '^forbidden:' "$OUT/gate.log" | awk '{print $2}')"
  detail="valid ${valid:-?} (need >=90%), forbidden ${forbidden:-?} (need 0), gate exit $code"
  if [[ "$code" == "0" ]]; then record T2 PASS "$detail"; else record T2 FAIL "$detail (log: $OUT/gate.log)"; fi
fi

# --------------------------------------------------------------------------
echo "== T3: end-to-end pipeline test"
swift test --filter EndToEndPipelineTests >"$OUT/e2e.log" 2>&1
code=$?
cases="$(grep -Eo 'E2E: [0-9]+/[0-9]+' "$OUT/e2e.log" | tail -1)"
tests="$(grep -E 'Executed [0-9]+ tests' "$OUT/e2e.log" | tail -1 | sed 's/^[[:space:]]*//')"
total="${cases##*/}"
if [[ "$code" == "0" && -n "$cases" && "${total:-0}" -ge 20 ]]; then
  record T3 PASS "$cases table cases + stepping/type-through/escape/focus/cold-model tests; $tests"
else
  record T3 FAIL "${cases:-no case count} (need >=20 passing); $tests (log: $OUT/e2e.log)"
fi

# --------------------------------------------------------------------------
echo "== T4: installed app is HEAD and stays running"
if [[ "$SKIP_INSTALL" == "1" ]]; then
  record T4 SKIP "skipped by flag"
else
  APP="$COTYPE_APP"
  PLIST="$APP/Contents/Info.plist"
  head="$(git rev-parse HEAD)"
  stamp="$(/usr/libexec/PlistBuddy -c 'Print :CotypeBuildGitCommitLong' "$PLIST" 2>/dev/null || echo missing)"
  dirty="$(/usr/libexec/PlistBuddy -c 'Print :CotypeBuildGitDirty' "$PLIST" 2>/dev/null || echo missing)"
  problems=()
  [[ "$stamp" == "$head" ]] || problems+=("stamp $stamp != HEAD $head")
  [[ "$dirty" == "false" ]] || problems+=("built from a dirty tree ($dirty)")
  if [[ -f "$COTYPE_DIST_APP/Contents/MacOS/Cotype" ]]; then
    dist_stamp="$(/usr/libexec/PlistBuddy -c 'Print :CotypeBuildGitCommitLong' "$COTYPE_DIST_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$dist_stamp" == "$head" ]]; then
      a="$(shasum -a 256 "$APP/Contents/MacOS/Cotype" | awk '{print $1}')"
      b="$(shasum -a 256 "$COTYPE_DIST_APP/Contents/MacOS/Cotype" | awk '{print $1}')"
      [[ "$a" == "$b" ]] || problems+=("installed binary differs from dist build of HEAD")
    fi
  fi
  exe="$APP/Contents/MacOS/Cotype"
  pid="$(pgrep -f "^$exe" | head -1 || true)"
  if [[ -z "$pid" ]]; then
    echo "Cotype is not running; launching it in the background."
    open -g "$APP"
    for _ in $(seq 1 20); do
      pid="$(pgrep -f "^$exe" | head -1 || true)"
      [[ -n "$pid" ]] && break
      sleep 0.5
    done
  fi
  if [[ -z "$pid" ]]; then
    problems+=("process did not start")
  else
    etime_s() { ps -o etime= -p "$1" | awk -F'[-:]' '{ n=NF; s=$n+0; if(n>1)s+=$(n-1)*60; if(n>2)s+=$(n-2)*3600; if(n>3)s+=$(n-3)*86400; print s }'; }
    age="$(etime_s "$pid")"
    if [[ "${age:-0}" -lt 60 ]]; then
      wait_s=$((61 - age))
      echo "Process $pid is ${age}s old; waiting ${wait_s}s."
      sleep "$wait_s"
    fi
    if kill -0 "$pid" 2>/dev/null; then
      age="$(etime_s "$pid")"
    else
      problems+=("process $pid exited within 60 s")
    fi
  fi
  if [[ ${#problems[@]} -eq 0 ]]; then
    record T4 PASS "installed ${stamp:0:7} = HEAD, clean tree, pid $pid alive ${age}s"
  else
    record T4 FAIL "$(IFS='; '; echo "${problems[*]}")"
  fi
fi

# --------------------------------------------------------------------------
echo "== T5: warm-model suggestion latency (production engine path)"
curl -s -m 200 -X POST http://127.0.0.1:8078/v1/warm -d '{"model":"gemma-it"}' >"$OUT/warm.json" 2>&1
swift run cotype-eval --engine daemon --max-tokens 24 >"$OUT/latency.log" 2>&1
median="$(grep -E '^median latency:' "$OUT/latency.log" | awk '{print $3}')"
p_valid="$(grep -E '^valid rate:' "$OUT/latency.log" | awk '{print $3}')"
failures="$(grep -E '^failures:' "$OUT/latency.log" | awk '{print $2}')"
if [[ -n "$median" && "${failures:-1}" == "0" ]]; then
  ms="$(awk -v s="$median" 'BEGIN{printf "%d", s*1000}')"
  detail="median ${ms} ms over 29 cases (target <400 ms; plus the 120 ms typing pause); production-path valid rate ${p_valid}"
  if [[ "$ms" -lt 400 ]]; then record T5 PASS "$detail"; else record T5 FAIL "$detail"; fi
else
  record T5 FAIL "no latency measured (failures ${failures:-?}; is Local Models running? log: $OUT/latency.log)"
fi

# --------------------------------------------------------------------------
if [[ -f "$ROOT/docs/acceptance-20260925.md" ]]; then
  record T6 MANUAL "the maintainer runs docs/acceptance-20260925.md in Helium, Slack and Notes"
else
  record T6 FAIL "docs/acceptance-20260925.md missing"
fi

echo
echo "================ Cotype acceptance ================"
printf '%s\n' "${RESULTS[@]}"
echo "logs: $OUT"
exit "$FAILED"
