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

make_target() {
    local target="$1"
    mkdir -p "$target"
    git -C "$target" init -q
    git -C "$target" config user.name "Result Contract Test"
    git -C "$target" config user.email "result-contract@example.com"
    printf '%s\n' 'echo review me' > "$target/app.sh"
    git -C "$target" add app.sh
    git -C "$target" commit -qm initial
}

cat > "$FAKE_BIN/result-agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

agent="$(basename "$0")"
prompt="$(cat)"
phase=1
[[ "$prompt" == *"Phase 2: Cross-Review"* ]] && phase=2
[[ "$prompt" == *"Phase 3: Meta-Review"* ]] && phase=3
[[ "$prompt" == *"Phase 4: Synthesis & Implementation"* ]] && phase=4

if [[ "${FAKE_FAIL_AGENT:-}" == "$agent" && "${FAKE_FAIL_PHASE:-}" == "$phase" ]]; then
    echo "simulated $agent backend failure"
    exit 17
fi

if [[ "${FAKE_FORCE_REVIEW_WRITE_PHASE:-}" == "$phase" && "$agent" == "claude" ]]; then
    printf '%s\n' 'unexpected review write' >> app.sh
fi

agent_upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
other_upper="CLAUDE"
[[ "$agent" == "claude" ]] && other_upper="CODEX"

case "$phase" in
    1)
        response="$agent_upper-1
---REVIEW_STATUS---
ISSUES_FOUND: 1
CRITICAL_COUNT: 0
HIGH_COUNT: 1
MEDIUM_COUNT: 0
LOW_COUNT: 0
ISSUE_SCOPES: $agent_upper-1=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: $agent found one issue
---END_REVIEW_STATUS---"
        [[ "${FAKE_PHASE1_CLEAN:-}" == "1" ]] && response="NO_ISSUES"
        ;;
    2)
        response="---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 1
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 0
ISSUE_SCOPES: $other_upper-1=IN_SCOPE
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: $agent validated the other reviewer
---END_CROSS_REVIEW_STATUS---"
        ;;
    3)
        response="---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 1
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 0
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CODEX-1=IN_SCOPE
SUMMARY: consensus reached
---END_META_REVIEW_STATUS---"
        ;;
    4)
        sandbox=""
        output_file=""
        previous=""
        for argument in "$@"; do
            [[ "$previous" == "-s" ]] && sandbox="$argument"
            [[ "$previous" == "-o" ]] && output_file="$argument"
            previous="$argument"
        done
        if [[ "$sandbox" == "read-only" ]]; then
            response="## Unresolved in-scope findings

- CLAUDE-1 and CODEX-1 remain unresolved.

## Pre-existing issues noticed, not fixed

- None.

---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 0
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 2
FILES_MODIFIED: 0
IN_SCOPE_FIXED: 0
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: findings reported without writes
---END_SYNTHESIS_STATUS---"
        else
            printf '%s\n' 'fixed by synthesis' >> app.sh
            if [[ -n "${FAKE_SYNTHESIS_IGNORED_FILE:-}" ]]; then
                printf '%s\n' 'ignored synthesis output' >> "$FAKE_SYNTHESIS_IGNORED_FILE"
            fi
            response="---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 1
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
FILES_MODIFIED: 1
IN_SCOPE_FIXED: 1
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: fix applied
---END_SYNTHESIS_STATUS---"
            if [[ "${FAKE_SYNTHESIS_CONTINUE:-}" == "1" ]]; then
                response="${response/EXIT_SIGNAL: true/EXIT_SIGNAL: false}"
            fi
            if [[ "${FAKE_APPLY_FINDINGS:-}" == "1" ]]; then
                response="${response/ISSUES_SKIPPED: 0/ISSUES_SKIPPED: 1}"
            fi
        fi
        ;;
esac

if [[ "${FAKE_SCOPE_CONFLICT:-}" == "1" && "$phase" -eq 3 &&
      "$agent" == "claude" ]]; then
    response="${response/CLAUDE-1=IN_SCOPE/CLAUDE-1=PRE_EXISTING}"
fi

if [[ "${FAKE_MALFORMED_AGENT:-}" == "$agent" &&
      "${FAKE_MALFORMED_PHASE:-}" == "$phase" ]]; then
    response="malformed response without a status block"
fi

if [[ "$agent" == "claude" ]]; then
    if [[ "$phase" -lt 4 ]]; then
        if [[ "${FAKE_DENIED_WRITE_AGENT:-}" == "claude" &&
              "${FAKE_DENIED_WRITE_PHASE:-}" == "$phase" ]]; then
            jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"printf denied > file"}}]}}'
        fi
        jq -cn --arg result "$response" \
            '{type:"result",subtype:"success",is_error:false,result:$result}'
    else
        printf '%s\n' "$response"
    fi
else
    output_file=""
    json_mode=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) output_file="$2"; shift 2 ;;
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done
    printf '%s\n' "$response" > "$output_file"
    if [[ "$json_mode" == "true" ]]; then
        if [[ "${FAKE_DENIED_WRITE_AGENT:-}" == "codex" &&
              "${FAKE_DENIED_WRITE_PHASE:-}" == "$phase" ]]; then
            jq -cn '{type:"item.completed",item:{type:"command_execution",status:"failed",aggregated_output:"sandbox denied: Read-only file system"}}'
        fi
        jq -cn '{type:"turn.completed",usage:{input_tokens:1,output_tokens:1}}'
    fi
fi
EOF

chmod +x "$FAKE_BIN/result-agent"
ln -s result-agent "$FAKE_BIN/claude"
ln -s result-agent "$FAKE_BIN/codex"

assert_result() {
    local result_file="$1"
    local expected_category="$2"
    local expected_reason="$3"

    [[ -f "$result_file" ]] || fail "requested result file was not written: $result_file"
    jq -e . "$result_file" >/dev/null || fail "result is not valid JSON: $result_file"
    [[ "$(jq -r '.termination.category' "$result_file")" == "$expected_category" ]] ||
        fail "unexpected termination category in $result_file"
    [[ "$(jq -r '.termination.reason' "$result_file")" == "$expected_reason" ]] ||
        fail "unexpected termination reason in $result_file"
    if find "$(dirname "$result_file")" -maxdepth 1 \
        -name ".$(basename "$result_file").tmp.*" -print -quit | grep -q .; then
        fail "atomic result write left a temporary file behind"
    fi
}

test_dry_run_result_cannot_be_mistaken_for_completed_review() {
    local target="$TEST_ROOT/dry-run-target"
    local result_file="$TEST_ROOT/dry-run-result.json"
    local output_file="$TEST_ROOT/dry-run.out"
    local status
    make_target "$target"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --apply-fixes --max-iters 1 \
        --result-file "$result_file" claude codex "$target" \
        > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "dry-run must retain incomplete-review exit 12"
    [[ -f "$result_file" ]] || fail "dry-run must atomically produce the requested result file"
    jq -e . "$result_file" >/dev/null || fail "dry-run result must be valid JSON"
    [[ "$(jq -r '.schema_version' "$result_file")" == "1" ]] ||
        fail "result schema must be versioned"
    [[ "$(jq -r '.execution.dry_run' "$result_file")" == "true" ]] ||
        fail "result must explicitly identify dry-run execution"
    [[ "$(jq -r '.execution.review_executed' "$result_file")" == "false" ]] ||
        fail "dry-run must not claim an actual review was executed"
    [[ "$(jq -r '.termination.category' "$result_file")" == "incomplete-review" ]] ||
        fail "dry-run must retain the stable public exit category"
    [[ "$(jq -r '.termination.reason' "$result_file")" == "max-iterations" ]] ||
        fail "dry-run must expose the specific termination reason"
    [[ "$(jq -r '.iterations' "$result_file")" == "1" ]] ||
        fail "dry-run result must report the attempted iteration count"
    [[ "$(jq -r '.synthesis.executed_by' "$result_file")" == "null" ]] ||
        fail "dry-run must not claim that a synthesis agent executed"
    pass "dry-run result is valid and cannot be mistaken for a completed review"
}

test_clean_phase_1_result() {
    local target="$TEST_ROOT/clean-phase1-target"
    local result_file="$TEST_ROOT/clean-phase1.json"
    local status
    make_target "$target"

    set +e
    FAKE_PHASE1_CLEAN=1 PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 0 ]] || fail "clean Phase 1 must exit 0"
    assert_result "$result_file" clean clean-phase-1
    [[ "$(jq -r '.iterations' "$result_file")" == "1" ]] ||
        fail "clean Phase 1 must record one iteration"
    [[ "$(jq -r '.synthesis.executed_by' "$result_file")" == "null" ]] ||
        fail "clean Phase 1 must not claim synthesis executed"
    pass "clean Phase 1 result captures the early clean exit"
}

test_clean_synthesis_result_and_target_changes() {
    local target="$TEST_ROOT/clean-synthesis-target"
    local result_file="$TEST_ROOT/clean-synthesis.json"
    local status
    make_target "$target"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --max-iters 1 --fixer codex \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 0 ]] || fail "clean synthesis must exit 0"
    assert_result "$result_file" clean clean-synthesis
    [[ "$(jq -r '.synthesis.executed_by' "$result_file")" == "codex" ]] ||
        fail "result must identify the actual synthesis agent"
    [[ "$(jq -c '.counts' "$result_file")" == '{"findings":{"in_scope":2,"pre_existing":0,"scope_conflicts":0},"fixes":{"in_scope":1,"pre_existing":0},"pre_existing_flagged":0}' ]] ||
        fail "finding and fix counts must come from parsed status data"
    [[ "$(jq -r '.target_changes.modified' "$result_file")" == "true" ]] ||
        fail "result must report a target write"
    [[ "$(jq -c '.target_changes.files' "$result_file")" == '["app.sh"]' ]] ||
        fail "result must list the file changed by apply-fixes"
    [[ "$(jq -r '.paths.final_synthesis_artifact' "$result_file")" == *'/artifacts/iter1_4_synthesis.md' ]] ||
        fail "result must expose the final synthesis artifact"
    [[ "$(jq -c '.reviewers' "$result_file")" == '{"slot_a":"claude","slot_b":"codex"}' ]] ||
        fail "result must expose the reviewer-slot assignment"
    [[ "$(jq -r '.target_repo.identity' "$result_file")" == "$target" ]] ||
        fail "result must expose a stable target repository identity"
    [[ "$(jq -r '.paths.state_dir' "$result_file")" == "$AR_STATE_ROOT"/* ]] ||
        fail "result must expose its target-scoped state directory"
    pass "clean synthesis result records parsed counts and actual target changes"
}

test_apply_fixes_findings_result() {
    local target="$TEST_ROOT/apply-findings-target"
    local result_file="$TEST_ROOT/apply-findings.json"
    local status
    make_target "$target"

    set +e
    FAKE_APPLY_FINDINGS=1 PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --max-iters 1 --fixer codex \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 11 ]] || fail "apply-fixes findings must exit 11"
    assert_result "$result_file" apply-fixes-findings-remain apply-fixes-findings-remain
    pass "apply-fixes unresolved findings retain their distinct result category"
}

test_review_only_findings_result() {
    local target="$TEST_ROOT/review-only-findings-target"
    local result_file="$TEST_ROOT/review-only-findings.json"
    local status
    make_target "$target"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --max-iters 1 --fixer codex \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 10 ]] || fail "review-only findings must exit 10"
    assert_result "$result_file" review-only-findings-remain review-only-findings-remain
    [[ "$(jq -r '.counts.findings.in_scope' "$result_file")" == "2" ]] ||
        fail "review-only result must retain resolved finding counts"
    [[ "$(jq -r '.counts.fixes.in_scope' "$result_file")" == "0" ]] ||
        fail "review-only result must not claim fixes"
    [[ "$(jq -r '.target_changes.modified' "$result_file")" == "false" ]] ||
        fail "review-only result must report an unchanged target"
    pass "review-only findings remain distinct in the result contract"
}

test_scope_conflicts_are_conservative_and_order_independent() {
    local target="$TEST_ROOT/scope-conflict-target"
    local result_file="$TEST_ROOT/scope-conflict.json"
    local status
    make_target "$target"

    set +e
    FAKE_SCOPE_CONFLICT=1 PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --max-iters 1 --fixer codex \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 10 ]] || fail "scope-conflict review must retain review-only findings exit 10"
    [[ "$(jq -c '.counts.findings' "$result_file")" == \
       '{"in_scope":1,"pre_existing":1,"scope_conflicts":1}' ]] ||
        fail "scope disagreement must conservatively classify PRE_EXISTING and remain visible"
    pass "scope conflicts are conservative instead of depending on reviewer order"
}

test_max_iterations_result() {
    local target="$TEST_ROOT/max-iterations-target"
    local result_file="$TEST_ROOT/max-iterations.json"
    local status
    make_target "$target"

    set +e
    FAKE_SYNTHESIS_CONTINUE=1 PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --max-iters 1 --fixer codex \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "max iterations must exit 12"
    assert_result "$result_file" incomplete-review max-iterations
    pass "max-iterations result remains distinguishable"
}

test_circuit_open_result() {
    local target="$TEST_ROOT/circuit-open-target"
    local result_file="$TEST_ROOT/circuit-open.json"
    local circuit_file circuit_tmp status
    make_target "$target"

    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --circuit-status claude codex "$target" >/dev/null 2>&1
    circuit_file="$(find "$AR_STATE_ROOT" -path '*circuit-open-target*/.circuit_breaker.json' -print -quit)"
    circuit_tmp="$TEST_ROOT/circuit-open-state.json"
    jq '.state = "OPEN" | .reason = "contract test"' "$circuit_file" > "$circuit_tmp"
    mv "$circuit_tmp" "$circuit_file"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "open circuit must exit 12"
    assert_result "$result_file" incomplete-review circuit-open
    [[ "$(jq -r '.execution.review_executed' "$result_file")" == "false" ]] ||
        fail "an open circuit must not claim any review Agent executed"
    pass "circuit-open result remains distinguishable"
}

test_malformed_agent_result() {
    local target="$TEST_ROOT/malformed-target"
    local result_file="$TEST_ROOT/malformed.json"
    local status
    make_target "$target"

    set +e
    FAKE_MALFORMED_AGENT=claude FAKE_MALFORMED_PHASE=1 \
        PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] || fail "malformed response must exit 70"
    assert_result "$result_file" agent-backend-failure malformed-agent-response
    pass "malformed Agent response produces a complete result"
}

test_backend_failure_result() {
    local target="$TEST_ROOT/backend-failure-target"
    local result_file="$TEST_ROOT/backend-failure.json"
    local status
    make_target "$target"

    set +e
    FAKE_FAIL_AGENT=codex FAKE_FAIL_PHASE=2 PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --apply-fixes --result-file "$result_file" \
        claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] || fail "backend failure must exit 70"
    assert_result "$result_file" agent-backend-failure agent-backend-failure
    pass "backend failure produces a complete result"
}

test_denied_write_attempt_result() {
    local target="$TEST_ROOT/denied-write-target"
    local result_file="$TEST_ROOT/denied-write.json"
    local status
    make_target "$target"

    set +e
    FAKE_DENIED_WRITE_AGENT=codex FAKE_DENIED_WRITE_PHASE=2 \
        PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 77 ]] || fail "denied write attempt must exit 77"
    assert_result "$result_file" write-boundary-violation write-boundary-violation
    pass "denied write attempt produces a boundary-violation result"
}

test_detected_target_write_result() {
    local target="$TEST_ROOT/detected-write-target"
    local result_file="$TEST_ROOT/detected-write.json"
    local status
    make_target "$target"

    set +e
    FAKE_FORCE_REVIEW_WRITE_PHASE=2 PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --apply-fixes --result-file "$result_file" \
        claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 77 ]] || fail "detected target write must exit 77"
    assert_result "$result_file" write-boundary-violation write-boundary-violation
    [[ "$(jq -c '.target_changes' "$result_file")" == '{"modified":true,"files":["app.sh"]}' ]] ||
        fail "boundary result must expose the target file that changed"
    pass "detected target write produces a complete result with changed paths"
}

test_invalid_base_ref_result() {
    local target="$TEST_ROOT/invalid-base-target"
    local result_file="$TEST_ROOT/invalid-base.json"
    local status
    make_target "$target"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --apply-fixes \
        --base does-not-exist --result-file "$result_file" \
        claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 64 ]] || fail "invalid base ref must exit 64"
    assert_result "$result_file" invalid-invocation invalid-base-ref
    [[ "$(jq -r '.scope.requested_base_ref' "$result_file")" == "does-not-exist" ]] ||
        fail "invalid-base result must retain the requested ref"
    [[ "$(jq -r '.scope.resolved_base_commit' "$result_file")" == "null" ]] ||
        fail "invalid-base result must not invent a resolved commit"
    pass "invalid base ref produces a complete preflight result"
}

test_resolved_base_scope_result() {
    local target="$TEST_ROOT/resolved-base-target"
    local result_file="$TEST_ROOT/resolved-base.json"
    local expected_commit status
    make_target "$target"
    expected_commit="$(git -C "$target" rev-parse HEAD)"
    printf '%s\n' 'echo changed' > "$target/app.sh"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --dry-run --apply-fixes \
        --max-iters 1 --base HEAD --result-file "$result_file" \
        claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "base-scoped dry-run must exit 12"
    assert_result "$result_file" incomplete-review max-iterations
    [[ "$(jq -c '.scope' "$result_file")" == \
       "{\"kind\":\"base\",\"requested_base_ref\":\"HEAD\",\"resolved_base_commit\":\"$expected_commit\"}" ]] ||
        fail "result must expose the requested and resolved base ref"
    pass "base-scoped result exposes the resolved commit"
}

test_missing_dependency_result() {
    local target="$TEST_ROOT/missing-dependency-target"
    local result_file="$TEST_ROOT/missing-dependency.json"
    local status
    make_target "$target"

    set +e
    PATH="/usr/bin:/bin" "$SCRIPT_UNDER_TEST" --apply-fixes \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] || fail "missing dependency must exit 70"
    assert_result "$result_file" agent-backend-failure missing-dependency
    [[ "$(jq -r '.execution.review_executed' "$result_file")" == "false" ]] ||
        fail "dependency preflight failure must not claim review execution"
    pass "missing dependency produces valid JSON without relying on the missing backend"
}

test_result_is_written_only_after_destination_is_parsed() {
    local target="$TEST_ROOT/result-parse-target"
    local before_file="$TEST_ROOT/not-parsed.json"
    local after_file="$TEST_ROOT/parsed.json"
    make_target "$target"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --unknown-option \
        --result-file "$before_file" claude codex "$target" >/dev/null 2>&1
    set -e
    [[ ! -e "$before_file" ]] ||
        fail "result must not be written before argument parsing reaches its destination"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --result-file "$after_file" \
        --unknown-option claude codex "$target" >/dev/null 2>&1
    set -e
    assert_result "$after_file" invalid-invocation invalid-invocation
    pass "result emission begins only after --result-file is parsed"
}

test_result_file_does_not_change_terminal_output() {
    local target="$TEST_ROOT/terminal-output-target"
    local result_file="$TEST_ROOT/terminal-output.json"
    local without_result="$TEST_ROOT/without-result.out"
    local with_result="$TEST_ROOT/with-result.out"
    make_target "$target"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --dry-run --apply-fixes \
        --max-iters 1 claude codex "$target" > "$without_result" 2>&1
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --dry-run --apply-fixes \
        --max-iters 1 --result-file "$result_file" \
        claude codex "$target" > "$with_result" 2>&1
    set -e

    cmp -s <(sort "$without_result") <(sort "$with_result") ||
        fail "--result-file must not change existing terminal output content"
    pass "--result-file leaves terminal output format and content unchanged"
}

test_result_write_failure_is_not_silent() {
    local target="$TEST_ROOT/result-write-failure-target"
    local result_directory="$TEST_ROOT/result-is-a-directory"
    local output status
    make_target "$target"
    mkdir -p "$result_directory"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --dry-run \
        --apply-fixes --max-iters 1 --result-file "$result_directory" \
        claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "result persistence failure must preserve review exit status"
    [[ "$output" == *"Could not atomically write result file"* ]] ||
        fail "result persistence failure must emit a diagnostic"
    pass "result persistence failure is explicit and preserves the review status"
}

test_no_result_file_skips_result_snapshot() {
    local target="$TEST_ROOT/no-result-snapshot-target"
    make_target "$target"

    SCRIPT_UNDER_TEST="$SCRIPT_UNDER_TEST" TARGET_UNDER_TEST="$target" \
        FAKE_BIN_UNDER_TEST="$FAKE_BIN" bash -c '
            source "$SCRIPT_UNDER_TEST"
            target_file_manifest() { return 99; }
            PATH="$FAKE_BIN_UNDER_TEST:$PATH" main "$@" >/dev/null 2>&1
        ' result-snapshot-test --apply-fixes --max-iters 1 \
            claude codex "$target" ||
        fail "invocations without --result-file must not collect a result snapshot"
    pass "default invocations skip opt-in result snapshots"
}

test_result_changes_exclude_ignored_files() {
    local target="$TEST_ROOT/ignored-change-target"
    local result_file="$TEST_ROOT/ignored-change.json"
    make_target "$target"
    printf '%s\n' 'generated.log' > "$target/.gitignore"
    git -C "$target" add .gitignore
    git -C "$target" commit -qm ignore-generated
    printf '%s\n' 'existing' > "$target/generated.log"

    FAKE_SYNTHESIS_IGNORED_FILE=generated.log PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --apply-fixes --max-iters 1 --fixer codex \
        --result-file "$result_file" claude codex "$target" >/dev/null 2>&1 ||
        fail "ignored-file result run failed"
    [[ "$(jq -c '.target_changes.files' "$result_file")" == '["app.sh"]' ]] ||
        fail "target_changes must exclude git-ignored files"
    pass "result change detection excludes git-ignored files"
}

test_result_remote_url_redacts_credentials() {
    local target="$TEST_ROOT/credential-remote-target"
    local result_file="$TEST_ROOT/credential-remote.json"
    make_target "$target"
    git -C "$target" remote add origin \
        'https://ci-user:super-secret@example.com/org/repo.git'

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --dry-run --apply-fixes \
        --max-iters 1 --result-file "$result_file" \
        claude codex "$target" >/dev/null 2>&1
    set -e
    [[ "$(jq -r '.target_repo.remote_url' "$result_file")" == \
       'https://example.com/org/repo.git' ]] ||
        fail "result remote URL must strip embedded credentials"
    ! grep -q 'super-secret' "$result_file" ||
        fail "result JSON must not contain embedded remote credentials"
    pass "result repository identity redacts remote URL credentials"
}

test_dry_run_result_cannot_be_mistaken_for_completed_review
test_clean_phase_1_result
test_clean_synthesis_result_and_target_changes
test_apply_fixes_findings_result
test_review_only_findings_result
test_scope_conflicts_are_conservative_and_order_independent
test_max_iterations_result
test_circuit_open_result
test_malformed_agent_result
test_backend_failure_result
test_denied_write_attempt_result
test_detected_target_write_result
test_invalid_base_ref_result
test_resolved_base_scope_result
test_missing_dependency_result
test_result_is_written_only_after_destination_is_parsed
test_result_file_does_not_change_terminal_output
test_result_write_failure_is_not_silent
test_no_result_file_skips_result_snapshot
test_result_changes_exclude_ignored_files
test_result_remote_url_redacts_credentials

echo "1..$tests_run"
