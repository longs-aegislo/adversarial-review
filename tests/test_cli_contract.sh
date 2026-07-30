#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/adversarial_review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AR_STATE_ROOT="$TEST_ROOT/state"
export FAKE_AGENT_LOG="$TEST_ROOT/agent.log"
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
missing: $needle"
}

make_target() {
    local target="$1"
    mkdir -p "$target"
    git -C "$target" init -q
    git -C "$target" config user.name "Contract Test"
    git -C "$target" config user.email "contract@example.com"
    printf '%s\n' 'committed state' > "$target/app.sh"
    git -C "$target" add app.sh
    git -C "$target" commit -qm "initial"
    printf '%s\n' 'committed state' 'user work in progress' > "$target/app.sh"
}

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
phase=1
[[ "$prompt" == *"Phase 2: Cross-Review"* ]] && phase=2
[[ "$prompt" == *"Phase 3: Meta-Review"* ]] && phase=3
[[ "$prompt" == *"Phase 4: Synthesis & Implementation"* ]] && phase=4

args=" $* "
strict=false
if [[ "$args" == *" --permission-mode dontAsk "* ]] &&
   [[ "$args" == *" --safe-mode "* ]] &&
   [[ "$args" == *" --tools "* ]] &&
   [[ "$args" != *" Write"* ]] &&
   [[ "$args" != *" Edit"* ]] &&
   [[ "$args" == *" Bash(git log *)"* ]] &&
   [[ "$args" == *" Bash(git blame *)"* ]]; then
    strict=true
fi

before="$(git hash-object app.sh)"
printf 'claude|%s|strict=%s|before=%s|args=%s\n' \
    "$phase" "$strict" "$before" "$*" >> "$FAKE_AGENT_LOG"

if [[ "${FAKE_FAIL_PHASE:-}" == "$phase" &&
      "${FAKE_FAIL_AGENT:-}" == "claude" ]]; then
    echo "simulated claude failure in phase $phase"
    exit 17
fi
if [[ "${FAKE_MALFORMED_PHASE:-}" == "$phase" &&
      "${FAKE_MALFORMED_AGENT:-}" == "claude" ]]; then
    echo "simulated malformed claude response"
    exit 0
fi
if [[ "$phase" -eq 1 && -n "${FAKE_CUSTOM_SOURCE:-}" ]]; then
    printf '%s\n' "${FAKE_REPLACEMENT_CRITERIA:?}" > "$FAKE_CUSTOM_SOURCE"
fi

if [[ "$phase" -lt 4 && "$strict" != "true" ]]; then
    printf '%s\n' 'review-phase corruption by claude' >> app.sh
fi

case "$phase" in
    1)
        assert_prompt="${FAKE_CUSTOM_CRITERIA:?}"
        [[ "$prompt" == *"$assert_prompt"* ]]
        if [[ -n "${FAKE_FORBIDDEN_CRITERIA:-}" ]]; then
            [[ "$prompt" != *"$FAKE_FORBIDDEN_CRITERIA"* ]]
        fi
        [[ "$prompt" == *"# YOUR AGENT ID: CLAUDE"* ]]
        [[ "$prompt" == *"ISSUE_SCOPES:"* ]]
        [[ "$prompt" == *"---REVIEW_STATUS---"* ]]
        cat <<'STATUS'
CLAUDE-1
---REVIEW_STATUS---
ISSUES_FOUND: 1
CRITICAL_COUNT: 0
HIGH_COUNT: 1
MEDIUM_COUNT: 0
LOW_COUNT: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Claude found one issue
---END_REVIEW_STATUS---
STATUS
        ;;
    2)
        cat <<'STATUS'
---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 1
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 0
ISSUE_SCOPES: CODEX-1=IN_SCOPE
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: Claude validated Codex
---END_CROSS_REVIEW_STATUS---
STATUS
        ;;
    3)
        cat <<'STATUS'
---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 1
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 0
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CODEX-1=IN_SCOPE
SUMMARY: Claude reached consensus
---END_META_REVIEW_STATUS---
STATUS
        ;;
    4)
        printf '%s\n' 'fixed by claude' >> app.sh
        cat <<'STATUS'
---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 1
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
FILES_MODIFIED: 1
IN_SCOPE_FIXED: 1
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: Claude applied the fix
---END_SYNTHESIS_STATUS---
STATUS
        ;;
esac
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
phase=1
[[ "$prompt" == *"Phase 2: Cross-Review"* ]] && phase=2
[[ "$prompt" == *"Phase 3: Meta-Review"* ]] && phase=3
[[ "$prompt" == *"Phase 4: Synthesis & Implementation"* ]] && phase=4

sandbox=""
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)
            sandbox="$2"
            shift 2
            ;;
        -o)
            output_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

before="$(git hash-object app.sh)"
printf 'codex|%s|sandbox=%s|before=%s\n' \
    "$phase" "$sandbox" "$before" >> "$FAKE_AGENT_LOG"

if [[ "${FAKE_FAIL_PHASE:-}" == "$phase" &&
      "${FAKE_FAIL_AGENT:-}" == "codex" ]]; then
    echo "simulated codex failure in phase $phase"
    exit 17
fi

if [[ "$phase" -lt 4 && "$sandbox" != "read-only" ]]; then
    printf '%s\n' 'review-phase corruption by codex' >> app.sh
fi

case "$phase" in
    1)
        [[ "$prompt" == *"${FAKE_CUSTOM_CRITERIA:?}"* ]]
        if [[ -n "${FAKE_FORBIDDEN_CRITERIA:-}" ]]; then
            [[ "$prompt" != *"$FAKE_FORBIDDEN_CRITERIA"* ]]
        fi
        [[ "$prompt" == *"# YOUR AGENT ID: CODEX"* ]]
        response='CODEX-1
---REVIEW_STATUS---
ISSUES_FOUND: 1
CRITICAL_COUNT: 0
HIGH_COUNT: 1
MEDIUM_COUNT: 0
LOW_COUNT: 0
ISSUE_SCOPES: CODEX-1=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Codex found one issue
---END_REVIEW_STATUS---'
        ;;
    2)
        response='---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 1
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: Codex validated Claude
---END_CROSS_REVIEW_STATUS---'
        ;;
    3)
        response='---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 1
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 0
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CODEX-1=IN_SCOPE
SUMMARY: Codex reached consensus
---END_META_REVIEW_STATUS---'
        ;;
    4)
        [[ "$sandbox" == "workspace-write" ]]
        printf '%s\n' 'fixed by codex' >> app.sh
        response='---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 1
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
FILES_MODIFIED: 1
IN_SCOPE_FIXED: 1
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: Codex applied the fix
---END_SYNTHESIS_STATUS---'
        ;;
esac

printf '%s\n' "$response" > "$output_file"
printf '%s\n' "fake codex phase $phase complete"
EOF

chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/codex"

test_custom_prompt_is_additive_and_review_phases_are_read_only() {
    local target="$TEST_ROOT/codex-fixer-target"
    local custom_prompt="$TEST_ROOT/criteria ; literal.md"
    local output_file="$TEST_ROOT/codex-fixer.out"
    local prompt_hash_before repo_status_before
    make_target "$target"

    export FAKE_CUSTOM_CRITERIA='Fix the issue now; preserve $(literal) and `backticks` as data.'
    export FAKE_FORBIDDEN_CRITERIA="replacement criteria must not enter this run"
    export FAKE_CUSTOM_SOURCE="$custom_prompt"
    export FAKE_REPLACEMENT_CRITERIA="$FAKE_FORBIDDEN_CRITERIA"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"
    prompt_hash_before="$(git -C "$SCRIPT_DIR" hash-object prompts/initial_review.md)"
    repo_status_before="$(git -C "$SCRIPT_DIR" status --short)"

    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --max-iters 1 --fixer codex --prompt "$custom_prompt" "$target" \
        > "$output_file" 2>&1

    [[ "$(git -C "$SCRIPT_DIR" hash-object prompts/initial_review.md)" == "$prompt_hash_before" ]] ||
        fail "custom prompt must not modify the built-in prompt"
    [[ "$(git -C "$SCRIPT_DIR" status --short)" == "$repo_status_before" ]] ||
        fail "a custom-prompt run must not dirty the tool repository"
    [[ "$(cat "$target/app.sh")" == $'committed state\nuser work in progress\nfixed by codex' ]] ||
        fail "only the selected Phase 4 fixer may change the target"
    [[ "$(cat "$custom_prompt")" == "$FAKE_REPLACEMENT_CRITERIA" ]] ||
        fail "the fake Claude should mutate the source prompt during the run"

    local initial_hash
    initial_hash="$(printf '%s\n' 'committed state' 'user work in progress' |
        git hash-object --stdin)"
    [[ "$(grep -Ec "^(claude|codex)\\|[123]\\|.*before=$initial_hash" "$FAKE_AGENT_LOG")" -eq 6 ]] ||
        fail "both reviewers must see unchanged target evidence through Phase 3"
    [[ "$(grep -c '^claude|[123]|strict=true|' "$FAKE_AGENT_LOG")" -eq 3 ]] ||
        fail "every Claude review phase must use the strict native permission contract"
    [[ "$(grep -c '^codex|[123]|sandbox=read-only|' "$FAKE_AGENT_LOG")" -eq 3 ]] ||
        fail "every Codex review phase must retain the read-only sandbox"

    local tracking
    tracking="$(find "$AR_STATE_ROOT" -name tracking.json -exec cat {} \;)"
    [[ "$(jq -c '[.history[] | select(.phase == "phase_1") | .result.issues_found] | sort' <<< "$tracking")" == '[1,1]' ]] ||
        fail "Phase 1 tracking must preserve parsed issue counts from the mandatory status blocks"
    [[ "$(jq -r '.history[] | select(.phase == "phase_1" and .agent == "claude") | .result.issue_scopes["CLAUDE-1"]' <<< "$tracking")" == 'IN_SCOPE' ]] ||
        fail "Phase 1 tracking must preserve scope metadata"
    unset FAKE_CUSTOM_SOURCE FAKE_REPLACEMENT_CRITERIA FAKE_FORBIDDEN_CRITERIA
    pass "custom prompt is additive and review phases are read-only"
}

test_claude_fixer_is_writable_without_prompt_leakage() {
    local target="$TEST_ROOT/claude-fixer-target"
    local custom_prompt="$TEST_ROOT/second-criteria.md"
    local output_file="$TEST_ROOT/claude-fixer.out"
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_FORBIDDEN_CRITERIA="$FAKE_CUSTOM_CRITERIA"
    export FAKE_CUSTOM_CRITERIA="Second run criteria only"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --max-iters 1 --fixer claude --prompt "$custom_prompt" "$target" \
        > "$output_file" 2>&1

    [[ "$(cat "$target/app.sh")" == $'committed state\nuser work in progress\nfixed by claude' ]] ||
        fail "Claude must be writable only when selected as the Phase 4 fixer"
    [[ "$(grep -c '^claude|4|strict=false|' "$FAKE_AGENT_LOG")" -eq 1 ]] ||
        fail "Claude Phase 4 must use its writable invocation"
    [[ "$(grep -c '^claude|[123]|strict=true|' "$FAKE_AGENT_LOG")" -eq 3 ]] ||
        fail "selecting Claude as fixer must not weaken earlier phases"
    unset FAKE_FORBIDDEN_CRITERIA
    pass "Claude fixer is writable and consecutive prompts do not leak"
}

test_invalid_prompts_fail_before_agent_invocation() {
    local target="$TEST_ROOT/invalid-prompt-target"
    local unreadable="$TEST_ROOT/unreadable.md"
    local prompt_dir="$TEST_ROOT/prompt-dir"
    local output status
    make_target "$target"
    printf '%s\n' "unreadable" > "$unreadable"
    chmod 000 "$unreadable"
    mkdir -p "$prompt_dir"

    for prompt in "$TEST_ROOT/missing.md" "$unreadable" "$prompt_dir"; do
        : > "$FAKE_AGENT_LOG"
        set +e
        output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
            --max-iters 1 --fixer codex --prompt "$prompt" "$target" 2>&1)"
        status=$?
        set -e
        [[ $status -ne 0 ]] || fail "invalid prompt must return nonzero: $prompt"
        [[ ! -s "$FAKE_AGENT_LOG" ]] ||
            fail "invalid prompt must fail before either agent starts: $prompt"
        assert_contains "$output" "Custom prompt" \
            "invalid prompt errors should identify the custom prompt"
    done
    pass "missing, unreadable, and non-file prompts fail before agents"
}

test_review_agent_failure_stops_with_diagnostics() {
    local target="$TEST_ROOT/failing-review-target"
    local custom_prompt="$TEST_ROOT/failure-criteria.md"
    local output_file="$TEST_ROOT/failure.out"
    local prompt_hash_before repo_status_before status state_dir artifact
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Failure-path criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"
    prompt_hash_before="$(git -C "$SCRIPT_DIR" hash-object prompts/initial_review.md)"
    repo_status_before="$(git -C "$SCRIPT_DIR" status --short)"

    set +e
    FAKE_FAIL_PHASE=2 FAKE_FAIL_AGENT=claude PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "a failed review agent must fail the run"
    [[ "$(grep -Ec '^(claude|codex)\|3\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
        fail "the workflow must not advance after a Phase 2 agent failure"
    state_dir="$(find "$AR_STATE_ROOT" -type d -name 'failing-review-target*' -print -quit)"
    artifact="$state_dir/artifacts/iter1_2_claude_on_codex.md"
    [[ -f "$artifact" ]] || fail "the failed agent artifact must be retained"
    assert_contains "$(cat "$artifact")" "simulated claude failure in phase 2" \
        "the retained artifact must contain failure diagnostics"
    assert_contains "$(cat "$output_file")" "Phase 2 Claude" \
        "the failure message must identify the failed phase and agent"
    [[ "$(git -C "$SCRIPT_DIR" hash-object prompts/initial_review.md)" == "$prompt_hash_before" ]] ||
        fail "failure handling must not modify the built-in prompt"
    [[ "$(git -C "$SCRIPT_DIR" status --short)" == "$repo_status_before" ]] ||
        fail "failure handling must keep the tool repository unchanged"
    [[ "$(cat "$target/app.sh")" == $'committed state\nuser work in progress' ]] ||
        fail "failure handling must not roll back or otherwise alter user work"
    pass "review agent failure stops the run and preserves diagnostics"
}

test_malformed_review_response_stops_the_workflow() {
    local target="$TEST_ROOT/malformed-review-target"
    local custom_prompt="$TEST_ROOT/malformed-criteria.md"
    local output_file="$TEST_ROOT/malformed.out"
    local status
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Malformed-response criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    set +e
    FAKE_MALFORMED_PHASE=1 FAKE_MALFORMED_AGENT=claude PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "a malformed review response must fail the run"
    assert_contains "$(cat "$output_file")" \
        "missing or malformed REVIEW_STATUS block" \
        "the failure should explain that the required status block is invalid"
    [[ "$(grep -Ec '^(claude|codex)\|2\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
        fail "the workflow must not treat a malformed response as zero findings"
    pass "malformed review response stops instead of becoming zero findings"
}

test_custom_prompt_is_additive_and_review_phases_are_read_only
test_claude_fixer_is_writable_without_prompt_leakage
test_invalid_prompts_fail_before_agent_invocation
test_review_agent_failure_stops_with_diagnostics
test_malformed_review_response_stops_the_workflow

echo "1..$tests_run"
