#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Cotype verification gate.
#
# Two lanes, with different failure semantics:
#
#   DETERMINISTIC (always required)
#     - swift build (debug + release; --debug-only or --release-only to narrow)
#     - swift test
#     - app bundle construction + validation (--no-app to skip)
#     These MUST pass; failure exits non-zero.
#
#   MODEL EVAL (explicit, model-equipped lane)
#     - Requires a real GGUF and a per-machine flag. There is a strict
#       distinction between two states:
#         * lane requested but model ABSENT  -> HARD FAIL (never silent pass)
#         * lane NOT requested              -> explicit "skipped" (exit 0)
#
# Usage:
#   ./scripts/verify.sh                    # deterministic only; skip model lane
#   ./scripts/verify.sh --model-lane       # require shared model; fail if absent
#   ./scripts/verify.sh --skip-model       # explicit skip (deterministic only)
#   ./scripts/verify.sh --mode=ci          # machine-readable output, no prompts
#   ./scripts/verify.sh --json             # emit a JSON result summary on stdout
#   ./scripts/verify.sh --no-app           # skip bundle construction/validation
#   ./scripts/verify.sh --debug-only|--release-only | [--build]
#
# Exit codes:
#   0 deterministic passed (and model lane, if requested, passed)
#   1 deterministic failed
#   2 deterministic passed but model lane was requested and the model is missing
#   3 unknown/unsupported option
#
# The model-eval scoreboard failing quality thresholds still fails the gate
# (exit 1). A scoreboard that always exits 0 is not a gate.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/shared.sh"

MODEL_LANE=0
SKIP_MODEL=0
CI="${COTYPE_CI:-0}"
JSON=0
DO_APP=1
BUILD="debug release"   # both by default

usage() { sed -n '2,20p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-lane|-m) MODEL_LANE=1; SKIP_MODEL=0; shift ;;
    --skip-model|-s) SKIP_MODEL=1; MODEL_LANE=0; shift ;;
    --mode=ci) CI=1; shift ;;
    --json) JSON=1; shift ;;
    --no-app) DO_APP=0; shift ;;
    --debug-only) BUILD="debug"; shift ;;
    --release-only) BUILD="release"; shift ;;
    --build) BUILD="debug release"; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) die "Unknown option: $1"; shift ;;
    *) die "Unexpected argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Self-test: prove the shell release helpers (semver / build monotonicity / arm64
# detection) behave before they are trusted by the gate. No build or model needed.
# ---------------------------------------------------------------------------
if [[ "${SELF_TEST:-0}" == "1" ]]; then
  local_fail=0
  chk() { "$@" || { echo "  FAIL: $*"; local_fail=$((local_fail + 1)); }; }
  echo "verify self-test: release helpers"
  chk is_positive_int 1
  chk is_positive_int 120
  chk is_semver 0.1.1
  chk semver_gt 0.1.1 0.1.0
  chk semver_gt 1.0.0 1.0.0-rc.1
  chk semver_gt 1.0.0-beta 1.0.0-alpha
  chk num_gt 1 2
  if is_positive_int 0; then echo "  FAIL: is_positive_int accepted 0"; local_fail=$((local_fail + 1)); fi
  if is_semver 0.1; then echo "  FAIL: is_semver accepted 0.1"; local_fail=$((local_fail + 1)); fi
  if semver_gt 0.1.0 0.1.1; then echo "  FAIL: semver_gt accepted downgrade"; local_fail=$((local_fail + 1)); fi
  if semver_gt 1.0.0-rc.1 1.0.0; then echo "  FAIL: semver_gt ranked prerelease above release"; local_fail=$((local_fail + 1)); fi
  # release_is_monotonic calls die() (exit) on failure, so run it in a subshell.
  if ( release_is_monotonic 0.1.0 120 0.1.1 119 ) >/dev/null 2>&1; then echo "  FAIL: monotonicity accepted downgrade"; local_fail=$((local_fail + 1)); fi
  if ( release_is_monotonic 0.1.0 120 0.1.0 121 ) >/dev/null 2>&1; then echo "  FAIL: monotonicity accepted build regression"; local_fail=$((local_fail + 1)); fi
  if ( release_is_monotonic 0.1.1 121 0.1.0 120 ) >/dev/null 2>&1; then :; else echo "  FAIL: monotonicity rejected a valid bump"; local_fail=$((local_fail + 1)); fi
  # YAML assertion: a workflow_dispatch (release) run must NOT be cancelable by a
  # push / PR on the same ref. The workflow splits concurrency by event — dispatch
  # uses a 'release-*' group with cancel-in-progress:false; push / PR uses a 'ci-*'
  # group with true.
  if [[ -f "$ROOT/.github/workflows/ci.yml" ]]; then
    if ! grep -q "github.event_name != 'workflow_dispatch'" "$ROOT/.github/workflows/ci.yml" \
       || ! grep -q "format('release-" "$ROOT/.github/workflows/ci.yml"; then
      echo "  FAIL: workflow_dispatch concurrency is not isolated from push/PR"; local_fail=$((local_fail + 1))
    fi
  else
    echo "  WARN: ci.yml not found; skipped concurrency assertion"
  fi

  # The build host must be arm64 (Apple Silicon). On an arm64 host this passes;
  # on a wrong-arch runner it dies, so the packaging gate fails clearly rather
  # than silently producing a non-arm64 artifact.
  chk require_apple_silicon_host
  # arm64 detection against a known arm64 Mach-O; tolerate a fresh checkout where
  # the release binary is not yet built by falling back to a system binary.
  if [[ -f "$ROOT/.build/release/cotype-update" ]]; then
    chk is_arm64_binary "$ROOT/.build/release/cotype-update"
  elif is_arm64_binary /bin/ps; then
    :
  else
    echo "  WARN: no arm64 binary available to test is_arm64_binary"; :
  fi
  if [[ "$local_fail" -ne 0 ]]; then die "verify self-test failed ($local_fail)."; fi
  echo "verify self-test: passed"
  exit 0
fi

# The product's normal lane is the shared Local Models registry copy. Keep the
# legacy private `COTYPE_MODEL` path for standalone installation, but evaluate
# what Cotype actually uses by default. CI/custom runners can override with
# `COTYPE_EVAL_MODEL` without changing installer behavior.
MODEL="${COTYPE_EVAL_MODEL:-$COTYPE_MODEL_SOURCE}"
# The model-eval release gate runs the FULL seeded suite by default. Zero means
# "no --limit", so the release gate is never reduced to a 3-case smoke. Set
# COTYPE_EVAL_CASES to a positive n only for a deliberate smoke run.
CASES="${COTYPE_EVAL_CASES:-0}"
MAX_TOKENS="${COTYPE_EVAL_MAX_TOKENS:-32}"

ci_log group "Cotype verify (CI=${CI})"

# ---------------------------------------------------------------------------
# Deterministic gate.
# ---------------------------------------------------------------------------
det_failed=0

for kind in $BUILD; do
  ci_log "Building ${kind}…"
  if ! swift build -c "$kind"; then det_failed=1; fi
done

ci_log "Running publish scrub…"
if [[ -f "$ROOT/scripts/scrub.sh" ]] && ! sh "$ROOT/scripts/scrub.sh"; then det_failed=1; fi

ci_log "Running deterministic tests…"
if ! swift test; then det_failed=1; fi

if [[ "$DO_APP" == "1" ]]; then
  ci_log "Building and validating app bundle…"
  if ! "$ROOT/scripts/build-app.sh" >/dev/null; then det_failed=1; fi
  if ! "$ROOT/scripts/verify-bundle.sh" "$COTYPE_DIST_APP"; then det_failed=1; fi
fi

if [[ "$det_failed" == "1" ]]; then
  if [[ "$JSON" == "1" ]]; then
    printf '{"lane":"deterministic","result":"fail"}\n'
  fi
  die "Deterministic gate failed (build or tests)."
fi

# ---------------------------------------------------------------------------
# Model eval lane.
# ---------------------------------------------------------------------------
model_result="skipped"
model_code=0

if [[ "$SKIP_MODEL" == "1" || "${COTYPE_MODEL_EVAL:-}" == "0" ]]; then
  ci_log "Model eval lane: explicitly skipped."
elif [[ "$MODEL_LANE" == "1" || "${COTYPE_MODEL_EVAL:-}" == "1" ]]; then
  if ! model_exists "$MODEL"; then
    if [[ "$JSON" == "1" ]]; then
      printf '{"lane":"model-eval","result":"missing-model","model":"%s"}\n' "$MODEL"
    fi
    # Deterministic passed, but the requested model lane cannot run.
    die "Model eval lane REQUESTED but no model at: $MODEL (required model missing, not an explicit skip)."
  fi
  if ! model_is_valid "$MODEL"; then
    if [[ "$JSON" == "1" ]]; then
      printf '{"lane":"model-eval","result":"checksum-mismatch","model":"%s"}\n' "$MODEL"
    fi
    die "Model checksum mismatch at: $MODEL (expected $COTYPE_MODEL_SHA256)."
  fi
  if [[ "$CASES" -gt 0 ]]; then
    ci_log "Running model eval lane (first $CASES cases, max $MAX_TOKENS tokens)…"
    EVAL_ARGS=(--engine llama --model "$MODEL" --limit "$CASES" --max-tokens "$MAX_TOKENS")
  else
    ci_log "Running model eval lane (FULL seeded suite, max $MAX_TOKENS tokens)…"
    EVAL_ARGS=(--engine llama --model "$MODEL" --max-tokens "$MAX_TOKENS")
  fi
  set +e
  COTYPE_CI="$CI" swift run cotype-eval "${EVAL_ARGS[@]}" \
    --model-repo "$COTYPE_MODEL_REPO" --model-revision "$COTYPE_MODEL_REVISION" --model-sha "$COTYPE_MODEL_SHA256"
  eval_code=$?
  set -e
  if [[ "$eval_code" != "0" ]]; then
    model_result="fail"; model_code=1
  else
    model_result="pass"
  fi
else
  ci_log "Model eval lane: not requested; skipping. (Use --model-lane to require a model; the deterministic gate never needs one.)"
fi

# ---------------------------------------------------------------------------
# Result.
# ---------------------------------------------------------------------------
if [[ "$JSON" == "1" ]]; then
  printf '{"lane":"deterministic","result":"pass","model_lane":"%s"}\n' "$model_result"
fi

if [[ "$model_code" != "0" ]]; then
  die "Model eval lane failed."
fi

ci_log "All selected lanes passed."
exit 0
