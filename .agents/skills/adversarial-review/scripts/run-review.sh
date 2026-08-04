#!/usr/bin/env bash

set -euo pipefail

fail() {
    echo "Adversarial Review stopped: $1" >&2
    exit "${2:-64}"
}

require_json() {
    local file="$1"
    jq -e . "$file" >/dev/null 2>&1 || fail "CLI did not produce valid machine JSON"
    [[ "$(jq -r '.schema_version' "$file")" == "1" ]] ||
        fail "unsupported result schema: $(jq -r '.schema_version // "missing"' "$file")"
}

require_run_contract() {
    local file="$1"
    local expected_dry_run="$2"
    local expected_review_executed="$3"

    [[ "$(jq -r '.target_repo.path' "$file")" == "$TARGET_DIR" ]] ||
        fail "CLI resolved a different Target Repo"
    [[ "$(jq -r '.scope.requested_base_ref' "$file")" == "$BASE_REF" ]] ||
        fail "CLI resolved a different baseline"
    [[ "$(jq -r '.reviewers.slot_a' "$file")" == "$SLOT_A" &&
       "$(jq -r '.reviewers.slot_b' "$file")" == "$SLOT_B" ]] ||
        fail "CLI resolved different reviewer slots"
    [[ "$(jq -r '.execution.mode' "$file")" == "review-only" &&
       "$(jq -r '.execution.dry_run' "$file")" == "$expected_dry_run" &&
       "$(jq -r '.execution.review_executed' "$file")" == "$expected_review_executed" ]] ||
        fail "CLI did not preserve the review-only execution contract"
}

require_cli_contract() {
    local help_output
    help_output="$("$CLI" --help 2>&1)" || fail "Adversarial Review CLI --help check failed"
    for option in --slot-a --slot-b --target-dir --dry-run --review-only --result-file; do
        [[ "$help_output" == *"$option"* ]] ||
            fail "Adversarial Review CLI does not support required option: $option"
    done
}

require_backend() {
    local backend="$1"
    command -v "$backend" >/dev/null 2>&1 ||
        fail "missing Agent backend executable: $backend"

    case "$backend" in
        claude)
            claude auth status >/dev/null 2>&1 ||
                fail "Claude authentication check failed; authenticate before running a review"
            ;;
        codex)
            codex login status >/dev/null 2>&1 ||
                fail "Codex authentication check failed; authenticate before running a review"
            ;;
        *) fail "unsupported reviewer backend: $backend" ;;
    esac
}

SKILL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLI="${ADVERSARIAL_REVIEW_BIN:-}"
BASE_REF=""
SLOT_A="claude"
SLOT_B="codex"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli) CLI="$2"; shift 2 ;;
        --base) BASE_REF="$2"; shift 2 ;;
        --slot-a) SLOT_A="$2"; shift 2 ;;
        --slot-b) SLOT_B="$2"; shift 2 ;;
        *) fail "unknown option: $1" ;;
    esac
done

command -v jq >/dev/null 2>&1 || fail "missing dependency: jq"
if [[ -z "$CLI" ]]; then
    CLI="$(command -v adversarial_review.sh 2>/dev/null || true)"
    if [[ -z "$CLI" && -x "$SKILL_SCRIPT_DIR/../../../../adversarial_review.sh" ]]; then
        CLI="$SKILL_SCRIPT_DIR/../../../../adversarial_review.sh"
    fi
fi
if [[ "$CLI" == */* ]]; then
    [[ -x "$CLI" ]] || fail "Adversarial Review CLI is not executable: $CLI"
else
    CLI="$(command -v "$CLI" 2>/dev/null || true)"
    [[ -n "$CLI" ]] || fail "Adversarial Review CLI was not found; set ADVERSARIAL_REVIEW_BIN or pass --cli"
fi
[[ "$SLOT_A" == "claude" || "$SLOT_A" == "codex" ]] ||
    fail "unsupported reviewer backend: $SLOT_A"
[[ "$SLOT_B" == "claude" || "$SLOT_B" == "codex" ]] ||
    fail "unsupported reviewer backend: $SLOT_B"

TARGET_DIR="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$TARGET_DIR" && -d "$TARGET_DIR" ]] || fail "current workspace is not a Git Target Repo"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

[[ -n "$BASE_REF" ]] || BASE_REF="HEAD"
git -C "$TARGET_DIR" rev-parse --verify --quiet --end-of-options "${BASE_REF}^{commit}" >/dev/null ||
    fail "baseline does not resolve to a commit: $BASE_REF"

TIMEOUT_CMD="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
if [[ -z "$TIMEOUT_CMD" ]]; then
    fail "missing timeout support: install GNU timeout (coreutils on macOS)"
fi
TIMEOUT_VERSION="$("$TIMEOUT_CMD" --version 2>/dev/null || true)"
[[ "$TIMEOUT_VERSION" == *"GNU coreutils"* ]] ||
    fail "incompatible timeout support: GNU timeout is required"
require_cli_contract
require_backend "$SLOT_A"
if [[ "$SLOT_B" != "$SLOT_A" ]]; then
    require_backend "$SLOT_B"
fi

echo "Target Repo: $TARGET_DIR"
echo "Baseline: $BASE_REF"
echo "Reviewer slots: $SLOT_A, $SLOT_B"
if [[ "$SLOT_A" == "$SLOT_B" ]]; then
    echo "Review diversity: same-model redundancy provides lower review diversity than heterogeneous reviewers"
fi
echo "Execution mode: review-only"

RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT
DRY_RESULT="$RUN_DIR/dry-run.json"
DRY_OUTPUT="$RUN_DIR/dry-run.out"
REAL_RESULT="$RUN_DIR/review.json"

set +e
"$CLI" --dry-run --review-only --base "$BASE_REF" \
    --slot-a "$SLOT_A" --slot-b "$SLOT_B" --target-dir "$TARGET_DIR" \
    --result-file "$DRY_RESULT" > "$DRY_OUTPUT" 2>&1
dry_status=$?
set -e

require_json "$DRY_RESULT"
require_run_contract "$DRY_RESULT" true false
[[ $dry_status -eq 12 ]] || fail "dry-run failed: $(jq -r '.termination.reason' "$DRY_RESULT")" "$dry_status"

scope_header="$(sed -n 's/.*Files in scope (\([0-9][0-9]*\)):.*/\1/p' "$DRY_OUTPUT" | tail -1)"
[[ -n "$scope_header" && "$scope_header" -gt 0 ]] || fail "dry-run returned an empty or invalid Review Scope"
scope_files=()
while IFS= read -r scope_file; do
    scope_files+=("$scope_file")
done < <(awk -v count="$scope_header" '
    /Files in scope \([0-9]+\):/ { reading=1; next }
    reading && captured < count {
        sub(/^[[:space:]]+/, "")
        print
        captured++
    }
' "$DRY_OUTPUT")
[[ ${#scope_files[@]} -eq $scope_header ]] || fail "dry-run Review Scope could not be parsed safely"
echo "Review Scope ($scope_header): ${scope_files[*]}"

set +e
"$CLI" --review-only --base "$BASE_REF" \
    --slot-a "$SLOT_A" --slot-b "$SLOT_B" --target-dir "$TARGET_DIR" \
    --result-file "$REAL_RESULT"
review_status=$?
set -e

require_json "$REAL_RESULT"
require_run_contract "$REAL_RESULT" false true

category="$(jq -r '.termination.category' "$REAL_RESULT")"
case "$category" in
    clean)
        echo "Review result: clean"
        ;;
    review-only-findings-remain)
        echo "Review result: Findings remaining (in scope: $(jq -r '.counts.findings.in_scope' "$REAL_RESULT"), pre-existing: $(jq -r '.counts.findings.pre_existing' "$REAL_RESULT"))"
        ;;
    *)
        echo "Review result: stopped ($(jq -r '.termination.reason' "$REAL_RESULT"))"
        ;;
esac
echo "Synthesis: $(jq -r '.paths.final_synthesis_artifact // "not produced"' "$REAL_RESULT")"
echo "Artifacts: $(jq -r '.paths.artifacts_dir // "not produced"' "$REAL_RESULT")"
exit "$review_status"
