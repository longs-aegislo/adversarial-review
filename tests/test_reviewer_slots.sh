#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/adversarial_review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AR_STATE_ROOT="$TEST_ROOT/state"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

tests_run=0

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    tests_run=$((tests_run + 1))
    echo "ok $tests_run - $1"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$message
missing: $needle
output:
$haystack"
}

make_target() {
    local target="$1"
    mkdir -p "$target"
    git -C "$target" init -q
    git -C "$target" config user.name "Slot Test"
    git -C "$target" config user.email "slot@example.com"
    printf '%s\n' 'echo target' > "$target/app.sh"
    git -C "$target" add app.sh
    git -C "$target" commit -qm initial
}

run_cli() {
    local output_file="$1"
    shift
    set +e
    PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_UNDER_TEST" "$@" > "$output_file" 2>&1
    CLI_STATUS=$?
    set -e
    CLI_OUTPUT="$(cat "$output_file")"
}

assert_successful_assignment() {
    local name="$1"
    local expected_a="$2"
    local expected_b="$3"
    shift 3
    local output_file="$TEST_ROOT/$name.out"

    run_cli "$output_file" --dry-run --max-iters 1 "$@"
    assert_contains "$CLI_OUTPUT" "Slot A reviewer: $expected_a" \
        "$name should report slot A"
    assert_contains "$CLI_OUTPUT" "Slot B reviewer: $expected_b" \
        "$name should report slot B"
    pass "$name"
}

test_cli_forms_and_validation() {
    local target="$TEST_ROOT/forms-target"
    make_target "$target"

    assert_successful_assignment positional-only claude codex \
        claude codex "$target"
    assert_successful_assignment flag-only codex claude \
        --slot-a codex --slot-b claude --target-dir "$target"
    assert_successful_assignment mixed codex claude \
        codex --slot-b claude --target-dir "$target"

    run_cli "$TEST_ROOT/old-form.out" --dry-run "$target"
    [[ $CLI_STATUS -ne 0 ]] || fail "old single-positional form must fail"
    assert_contains "$CLI_OUTPUT" "slot-b" \
        "old form should identify missing reviewer-slot input"

    run_cli "$TEST_ROOT/invalid.out" --dry-run llama codex "$target"
    [[ $CLI_STATUS -ne 0 ]] || fail "invalid backend must fail"
    assert_contains "$CLI_OUTPUT" "Invalid slot-a backend" \
        "invalid backend error should identify slot-a"
    pass "old and invalid forms fail fast"

    run_cli "$TEST_ROOT/same.out" --dry-run codex codex "$target"
    assert_contains "$CLI_OUTPUT" "reduced review diversity" \
        "same-backend assignment should warn about reduced diversity"
    pass "same-backend redundancy warns but succeeds"

    run_cli "$TEST_ROOT/status.out" --status codex codex "$target"
    [[ $CLI_STATUS -eq 0 ]] || fail "status should succeed with explicit slots"
    assert_contains "$CLI_OUTPUT" "Slot A reviewer: codex" \
        "status should surface resolved slot A"
    assert_contains "$CLI_OUTPUT" "Slot B reviewer: codex" \
        "status should surface resolved slot B"
    pass "status surfaces the resolved reviewer assignment"
}

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
phase=1
[[ "$prompt" == *"Phase 2: Cross-Review"* ]] && phase=2
[[ "$prompt" == *"Phase 3: Meta-Review"* ]] && phase=3
[[ "$prompt" == *"Phase 4: Synthesis & Implementation"* ]] && phase=4

tag="CODEX-A"
[[ "$prompt" == *"# REVIEWER SLOT: slot-b"* ]] && tag="CODEX-B"
other_tag="CODEX-B"
[[ "$tag" == "CODEX-B" ]] && other_tag="CODEX-A"
printf '%s\n' "$prompt" > "$FAKE_PROMPT_DIR/${phase}-${tag}.txt"

output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        *) shift ;;
    esac
done

case "$phase" in
    1)
        response="$tag-1
---REVIEW_STATUS---
ISSUES_FOUND: 1
CRITICAL_COUNT: 0
HIGH_COUNT: 0
MEDIUM_COUNT: 1
LOW_COUNT: 0
ISSUE_SCOPES: $tag-1=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: finding from $tag
---END_REVIEW_STATUS---"
        ;;
    2)
        response="VERDICTS: $other_tag-1=VALID
---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 1
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 0
ISSUE_SCOPES: $other_tag-1=IN_SCOPE
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: cross review from $tag
---END_CROSS_REVIEW_STATUS---"
        ;;
    3)
        response="SCOPE_RECONCILIATION: NONE
---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 1
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 0
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 0
ISSUE_SCOPES: $tag-1=IN_SCOPE
SUMMARY: meta review from $tag
---END_META_REVIEW_STATUS---"
        ;;
    4)
        response="---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 0
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
IN_SCOPE_FIXED: 0
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
TESTS_RUN: YES
TESTS_PASSING: YES
FILES_MODIFIED: 0
EXIT_SIGNAL: true
SUMMARY: done
---END_SYNTHESIS_STATUS---"
        ;;
esac

printf '%s\n' "$response" > "$output_file"
jq -cn '{type: "turn.completed", usage: {input_tokens: 1, output_tokens: 1}}'
EOF
chmod +x "$FAKE_BIN/codex"

test_same_backend_prompts_and_artifacts_are_distinct() {
    local target="$TEST_ROOT/prompts-target"
    local state_dir
    make_target "$target"
    export FAKE_PROMPT_DIR="$TEST_ROOT/prompts"
    mkdir -p "$FAKE_PROMPT_DIR"

    run_cli "$TEST_ROOT/prompts.out" codex codex --target-dir "$target" \
        --max-iters 1 --fixer codex
    [[ $CLI_STATUS -eq 0 ]] || fail "same-backend fake run should succeed"

    assert_contains "$(cat "$FAKE_PROMPT_DIR/2-CODEX-A.txt")" \
        "The other reviewer uses the codex backend." \
        "slot A cross-review prompt should name slot B's backend"
    assert_contains "$(cat "$FAKE_PROMPT_DIR/3-CODEX-B.txt")" \
        "The other reviewer uses the codex backend." \
        "slot B meta-review prompt should name slot A's backend"

    state_dir="$(find "$AR_STATE_ROOT" -type d -name 'prompts-target*' -print -quit)"
    [[ -f "$state_dir/artifacts/iter1_1_codex_review.md" ]] ||
        fail "first Codex artifact should keep the established backend filename"
    [[ -f "$state_dir/artifacts/iter1_1_codex_review_2.md" ]] ||
        fail "second same-backend artifact should be preserved without collision"
    pass "same-backend prompts substitute names and artifacts remain distinct"
}

test_cli_forms_and_validation
test_same_backend_prompts_and_artifacts_are_distinct

echo "1..$tests_run"
