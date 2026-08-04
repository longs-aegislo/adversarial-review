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

file_mtime() {
    local file="$1"
    if stat -f '%m:%Sm' "$file" >/dev/null 2>&1; then
        stat -f '%m:%Sm' "$file"
    else
        stat -c '%Y:%y' "$file"
    fi
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
   [[ "$args" == *" --output-format stream-json "* ]] &&
   [[ "$args" == *" --verbose "* ]] &&
   [[ "$args" != *" Write"* ]] &&
   [[ "$args" != *" Edit"* ]] &&
   [[ "$args" == *" Bash(git log:*)"* ]] &&
   [[ "$args" == *" Bash(git blame:*)"* ]]; then
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
if [[ "${FAKE_FORCE_REVIEW_WRITE_PHASE:-}" == "$phase" ]]; then
    printf '%s\n' 'detected review-phase write by claude' >> app.sh
fi

response=""
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
        response="$(cat <<'STATUS'
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
)"
        ;;
    2)
        response="$(cat <<'STATUS'
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
)"
        ;;
    3)
        response="$(cat <<'STATUS'
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
)"
        ;;
    4)
        if [[ "$strict" == "true" ]]; then
            [[ "$prompt" == *"Unresolved in-scope findings"* ]]
            [[ "$prompt" == *"Pre-existing issues noticed, not fixed"* ]]
            response="$(cat <<'STATUS'
## Unresolved in-scope findings

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
SUMMARY: Reported two unresolved in-scope findings without modifying files
---END_SYNTHESIS_STATUS---
STATUS
)"
        else
            printf '%s\n' 'fixed by claude' >> app.sh
            response="$(cat <<'STATUS'
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
)"
        fi
        ;;
esac

if [[ "${FAKE_PHASE1_CLEAN:-}" == "1" ]]; then
    case "$phase" in
        1) response="NO_ISSUES" ;;
        2) response='---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 0
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 0
ISSUE_SCOPES: NONE
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: No findings to cross-review
---END_CROSS_REVIEW_STATUS---' ;;
        3) response='---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 0
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 0
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 0
ISSUE_SCOPES: NONE
SUMMARY: Clean review confirmed
---END_META_REVIEW_STATUS---' ;;
        4) response='## Unresolved in-scope findings

- None.

## Pre-existing issues noticed, not fixed

- None.

---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 0
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
FILES_MODIFIED: 0
IN_SCOPE_FIXED: 0
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: Review confirmed clean
---END_SYNTHESIS_STATUS---' ;;
    esac
elif [[ "$phase" -eq 1 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/CLAUDE-1/CLAUDE-1\n\nCLAUDE-2 pre-existing finding}"
    response="${response/ISSUES_FOUND: 1/ISSUES_FOUND: 2}"
    response="${response/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING}"
elif [[ "$phase" -eq 2 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/FINDINGS_VALIDATED: 1/FINDINGS_VALIDATED: 2}"
    response="${response/ISSUE_SCOPES: CODEX-1=IN_SCOPE/ISSUE_SCOPES: CODEX-1=IN_SCOPE, CODEX-2=PRE_EXISTING}"
elif [[ "$phase" -eq 3 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CODEX-1=IN_SCOPE/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING, CODEX-1=IN_SCOPE, CODEX-2=PRE_EXISTING}"
elif [[ "$phase" -eq 4 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/- None./- CLAUDE-2 is pre-existing and remains unresolved.}"
    response="${response/PRE_EXISTING_FLAGGED: 0/PRE_EXISTING_FLAGGED: 1}"
fi

if [[ "$phase" -lt 4 && "$args" == *" --output-format stream-json "* ]]; then
    if [[ "$phase" -eq 1 ]]; then
        jq -cn '{
            type: "assistant",
            message: {
                content: [{
                    type: "tool_use",
                    name: "Bash",
                    input: {command: "git log -1 -- app.sh"}
                }]
            }
        }'
    fi
    if [[ "${FAKE_DENIED_WRITE_PHASE:-}" == "$phase" &&
          "${FAKE_DENIED_WRITE_AGENT:-claude}" == "claude" ]]; then
        jq -cn '{
            type: "assistant",
            message: {
                content: [{
                    type: "tool_use",
                    name: "Bash",
                    input: {command: "printf denied > review-write.txt"}
                }]
            }
        }'
    fi
    jq -cn --arg result "$response" '{
        type: "result",
        subtype: "success",
        is_error: false,
        result: $result
    }'
else
    printf '%s\n' "$response"
fi
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
json_mode=false
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
        --json)
            json_mode=true
            shift
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
        if [[ "$sandbox" == "read-only" ]]; then
            [[ "$prompt" == *"Unresolved in-scope findings"* ]]
            [[ "$prompt" == *"Pre-existing issues noticed, not fixed"* ]]
            response='## Unresolved in-scope findings

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
SUMMARY: Reported two unresolved in-scope findings without modifying files
---END_SYNTHESIS_STATUS---'
        else
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
        fi
        ;;
esac

if [[ "${FAKE_PHASE1_CLEAN:-}" == "1" ]]; then
    case "$phase" in
        1) response='NO_ISSUES' ;;
        2) response='---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 0
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 0
ISSUE_SCOPES: NONE
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: No findings to cross-review
---END_CROSS_REVIEW_STATUS---' ;;
        3) response='---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 0
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 0
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 0
ISSUE_SCOPES: NONE
SUMMARY: Clean review confirmed
---END_META_REVIEW_STATUS---' ;;
        4) response='## Unresolved in-scope findings

- None.

## Pre-existing issues noticed, not fixed

- None.

---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 0
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
FILES_MODIFIED: 0
IN_SCOPE_FIXED: 0
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: Review confirmed clean
---END_SYNTHESIS_STATUS---' ;;
    esac
elif [[ "$phase" -eq 1 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/CODEX-1/CODEX-1\n\nCODEX-2 pre-existing finding}"
    response="${response/ISSUES_FOUND: 1/ISSUES_FOUND: 2}"
    response="${response/ISSUE_SCOPES: CODEX-1=IN_SCOPE/ISSUE_SCOPES: CODEX-1=IN_SCOPE, CODEX-2=PRE_EXISTING}"
elif [[ "$phase" -eq 2 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/FINDINGS_VALIDATED: 1/FINDINGS_VALIDATED: 2}"
    response="${response/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING}"
elif [[ "$phase" -eq 3 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    response="${response/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CODEX-1=IN_SCOPE/ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING, CODEX-1=IN_SCOPE, CODEX-2=PRE_EXISTING}"
elif [[ "$phase" -eq 4 && "${FAKE_PRE_EXISTING_FINDING:-}" == "1" ]]; then
    if [[ "$sandbox" == "read-only" ]]; then
        response="${response/- None./- CLAUDE-2 and CODEX-2 are pre-existing and remain unresolved.}"
    else
        response="## Pre-existing issues noticed, not fixed

- CLAUDE-2 and CODEX-2 are pre-existing and remain unresolved.

$response"
    fi
    response="${response/PRE_EXISTING_FLAGGED: 0/PRE_EXISTING_FLAGGED: 2}"
fi

if [[ "$phase" -eq 4 && "${FAKE_BAD_REVIEW_ONLY_SYNTHESIS:-}" == "missing-sections" ]]; then
    response='---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 0
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 2
FILES_MODIFIED: 0
IN_SCOPE_FIXED: 0
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
EXIT_SIGNAL: true
SUMMARY: Incomplete read-only report
---END_SYNTHESIS_STATUS---'
elif [[ "$phase" -eq 4 && "${FAKE_BAD_REVIEW_ONLY_SYNTHESIS:-}" == "claims-fixes" ]]; then
    response="${response/HIGH_CONFIDENCE_FIXES: 0/HIGH_CONFIDENCE_FIXES: 1}"
elif [[ "$phase" -eq 4 && "${FAKE_BAD_REVIEW_ONLY_SYNTHESIS:-}" == "omits-findings" ]]; then
    response="${response/- CLAUDE-1 and CODEX-1 remain unresolved./- None.}"
elif [[ "$phase" -eq 4 && "${FAKE_BAD_REVIEW_ONLY_SYNTHESIS:-}" == "claims-fixes-in-prose" ]]; then
    response="${response/SUMMARY: Reported two unresolved in-scope findings without modifying files/SUMMARY: All findings were fixed}"
fi

printf '%s\n' "$response" > "$output_file"
if [[ "$json_mode" == "true" ]]; then
    jq -cn '{type: "thread.started", thread_id: "fake-thread"}'
    if [[ "${FAKE_DENIED_WRITE_PHASE:-}" == "$phase" &&
          "${FAKE_DENIED_WRITE_AGENT:-claude}" == "codex" ]]; then
        jq -cn '{
            type: "item.completed",
            item: {
                id: "denied-write",
                type: "command_execution",
                command: "printf denied > review-write.txt",
                status: "failed",
                exit_code: 1,
                aggregated_output: "sandbox denied: Read-only file system"
            }
        }'
    fi
    if [[ "${FAKE_TURN_FAILURE_PHASE:-}" == "$phase" ]]; then
        jq -cn '{
            type: "turn.failed",
            error: {message: "simulated ordinary backend turn failure"}
        }'
    fi
    jq -cn '{type: "turn.completed", usage: {input_tokens: 1, output_tokens: 1}}'
else
    printf '%s\n' "fake codex phase $phase complete"
fi
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

    if ! PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --max-iters 1 --fixer codex --prompt "$custom_prompt" claude codex "$target" \
        > "$output_file" 2>&1; then
        fail "Codex-fixer contract run failed:
$(cat "$output_file")"
    fi

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
    [[ "$(jq -r '[.history[].result | type] | unique | join(",")' <<< "$tracking")" == 'string' ]] ||
        fail "tracking history result values must retain the existing string schema"
    [[ "$(jq -c '[.history[] | select(.phase == "phase_1") | (.result | fromjson).issues_found] | sort' <<< "$tracking")" == '[1,1]' ]] ||
        fail "Phase 1 tracking must preserve parsed issue counts from the mandatory status blocks"
    [[ "$(jq -r '.history[] | select(.phase == "phase_1" and .agent == "claude") | (.result | fromjson).issue_scopes["CLAUDE-1"]' <<< "$tracking")" == 'IN_SCOPE' ]] ||
        fail "Phase 1 tracking must preserve scope metadata"
    [[ "$(jq -r '.history[] | select(.phase == "phase_1" and .agent == "claude") | (.result | fromjson).summary' <<< "$tracking")" == 'Claude found one issue' ]] ||
        fail "Phase 1 tracking must preserve the parsed summary without changing its schema"
    local invocation_metadata
    invocation_metadata="$(find "$AR_STATE_ROOT" -name '*.invocation.json' \
        -exec jq -c . {} \; | jq -sc '.')"
    [[ "$(jq '[.[] | select(.phase != "phase_4" and .write_authorized == false)] | length' <<< "$invocation_metadata")" -eq 6 ]] ||
        fail "artifacts must record all six review invocations as read-only"
    [[ "$(jq '[.[] | select(.phase == "phase_4" and .agent == "codex" and .write_authorized == true)] | length' <<< "$invocation_metadata")" -eq 1 ]] ||
        fail "artifacts must identify the selected Phase 4 fixer as write-authorized"
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

    if ! PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --max-iters 1 --fixer claude --prompt "$custom_prompt" claude codex "$target" \
        > "$output_file" 2>&1; then
        fail "Claude-fixer contract run failed:
$(cat "$output_file")"
    fi

    [[ "$(cat "$target/app.sh")" == $'committed state\nuser work in progress\nfixed by claude' ]] ||
        fail "Claude must be writable only when selected as the Phase 4 fixer"
    [[ "$(grep -c '^claude|4|strict=false|' "$FAKE_AGENT_LOG")" -eq 1 ]] ||
        fail "Claude Phase 4 must use its writable invocation"
    [[ "$(grep -c '^claude|[123]|strict=true|' "$FAKE_AGENT_LOG")" -eq 3 ]] ||
        fail "selecting Claude as fixer must not weaken earlier phases"
    unset FAKE_FORBIDDEN_CRITERIA
    pass "Claude fixer is writable and consecutive prompts do not leak"
}

test_review_only_phase_4_is_read_only_and_preserves_target() {
    local target="$TEST_ROOT/review-only-target"
    local custom_prompt="$TEST_ROOT/review-only-criteria.md"
    local output_file="$TEST_ROOT/review-only.out"
    local content_before mtime_before state_dir synthesis invocation_metadata status
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Review-only criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"
    content_before="$(cat "$target/app.sh")"
    mtime_before="$(file_mtime "$target/app.sh")"

    set +e
    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" \
        > "$output_file" 2>&1
    status=$?
    set -e
    [[ $status -eq 10 ]] || fail "review-only findings must use status 10, got $status:
$(cat "$output_file")"

    [[ "$(cat "$target/app.sh")" == "$content_before" ]] ||
        fail "review-only must preserve target file content"
    [[ "$(file_mtime "$target/app.sh")" == "$mtime_before" ]] ||
        fail "review-only must preserve target file mtime"
    [[ "$(grep -c '^codex|4|sandbox=read-only|' "$FAKE_AGENT_LOG")" -eq 1 ]] ||
        fail "review-only Phase 4 must use Codex's read-only backend path"
    [[ "$(grep -Ec '^(claude|codex)\|[123]\|' "$FAKE_AGENT_LOG")" -eq 6 ]] ||
        fail "review-only must still complete all six Phase 1-3 invocations"

    state_dir="$(find "$AR_STATE_ROOT" -type d -name 'review-only-target*' -print -quit)"
    synthesis="$state_dir/artifacts/iter1_4_synthesis.md"
    assert_contains "$(cat "$synthesis")" "Unresolved in-scope findings" \
        "review-only synthesis must report unresolved in-scope findings"
    assert_contains "$(cat "$synthesis")" "Pre-existing issues noticed, not fixed" \
        "review-only synthesis must report pre-existing findings separately"
    [[ "$(jq -r '.status' "$state_dir/tracking.json")" == "review_complete_findings" ]] ||
        fail "review-only completion must not mark unresolved findings as clean"

    invocation_metadata="$(find "$state_dir" -name '*.invocation.json' \
        -exec jq -c . {} \; | jq -sc '.')"
    [[ "$(jq '[.[] | select(.execution_mode == "review-only")] | length' <<< "$invocation_metadata")" -eq 7 ]] ||
        fail "every review-only invocation must record the effective execution mode"
    [[ "$(jq '[.[] | select(.phase == "phase_4" and .write_authorized == false)] | length' <<< "$invocation_metadata")" -eq 1 ]] ||
        fail "review-only Phase 4 metadata must record that writes were not authorized"
    pass "review-only completes synthesis without changing target evidence"
}

test_apply_fixes_authorizes_only_phase_4_and_records_mode() {
    local target="$TEST_ROOT/explicit-apply-fixes-target"
    local custom_prompt="$TEST_ROOT/explicit-apply-fixes-criteria.md"
    local output_file="$TEST_ROOT/explicit-apply-fixes.out"
    local state_dir invocation_metadata
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Explicit apply-fixes criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    if ! PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" \
        > "$output_file" 2>&1; then
        fail "apply-fixes contract run failed:
$(cat "$output_file")"
    fi

    state_dir="$(find "$AR_STATE_ROOT" -type d \
        -name 'explicit-apply-fixes-target*' -print -quit)"
    invocation_metadata="$(find "$state_dir" -name '*.invocation.json' \
        -exec jq -c . {} \; | jq -sc '.')"
    [[ "$(jq '[.[] | select(.execution_mode == "apply-fixes")] | length' <<< "$invocation_metadata")" -eq 7 ]] ||
        fail "every apply-fixes invocation must record the effective execution mode"
    [[ "$(jq '[.[] | select(.phase != "phase_4" and .write_authorized == false)] | length' <<< "$invocation_metadata")" -eq 6 ]] ||
        fail "apply-fixes must leave all Phase 1-3 invocations read-only"
    [[ "$(jq '[.[] | select(.phase == "phase_4" and .write_authorized == true)] | length' <<< "$invocation_metadata")" -eq 1 ]] ||
        fail "apply-fixes must authorize writes only for Phase 4"
    pass "apply-fixes authorizes only Phase 4 and records its execution mode"
}

test_review_only_runs_all_phases_when_phase_1_is_clean() {
    local target="$TEST_ROOT/review-only-clean-target"
    local custom_prompt="$TEST_ROOT/review-only-clean-criteria.md"
    local output_file="$TEST_ROOT/review-only-clean.out"
    local state_dir
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Review-only clean criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    if ! FAKE_PHASE1_CLEAN=1 PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" \
        > "$output_file" 2>&1; then
        fail "clean review-only contract run failed:
$(cat "$output_file")"
    fi

    [[ "$(grep -Ec '^(claude|codex)\|[123]\|' "$FAKE_AGENT_LOG")" -eq 6 ]] ||
        fail "review-only must run Phases 2-3 even when Phase 1 is clean"
    [[ "$(grep -Ec '^(claude|codex)\|4\|' "$FAKE_AGENT_LOG")" -eq 1 ]] ||
        fail "review-only must run Phase 4 even when Phase 1 is clean"
    state_dir="$(find "$AR_STATE_ROOT" -type d \
        -name 'review-only-clean-target*' -print -quit)"
    [[ "$(jq -r '.status' "$state_dir/tracking.json")" == "review_complete" ]] ||
        fail "clean review-only execution must complete through synthesis"
    pass "review-only runs all four phases when Phase 1 reports no issues"
}

test_apply_fixes_clean_phase_1_exits_clean() {
    local target="$TEST_ROOT/apply-clean-target"
    local custom_prompt="$TEST_ROOT/apply-clean-criteria.md"
    local output_file="$TEST_ROOT/apply-clean.out"
    local status
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Apply clean criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    set +e
    FAKE_PHASE1_CLEAN=1 PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --apply-fixes --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" \
        > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 0 ]] || fail "clean Phase 1 must use clean status 0, got $status"
    [[ "$(grep -Ec '^(claude|codex)\|[234]\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
        fail "apply-fixes must stop after a clean Phase 1"
    pass "clean Phase 1 exits with clean status"
}

test_review_only_rejects_noncompliant_synthesis() {
    local failure_mode target custom_prompt output_file status

    for failure_mode in missing-sections claims-fixes omits-findings claims-fixes-in-prose; do
        target="$TEST_ROOT/review-only-bad-$failure_mode-target"
        custom_prompt="$TEST_ROOT/review-only-bad-$failure_mode-criteria.md"
        output_file="$TEST_ROOT/review-only-bad-$failure_mode.out"
        make_target "$target"
        : > "$FAKE_AGENT_LOG"
        export FAKE_CUSTOM_CRITERIA="Bad review-only criteria $failure_mode"
        printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

        set +e
        FAKE_BAD_REVIEW_ONLY_SYNTHESIS="$failure_mode" PATH="$FAKE_BIN:$PATH" \
            "$SCRIPT_UNDER_TEST" --review-only --max-iters 1 --fixer codex \
            --prompt "$custom_prompt" claude codex "$target" \
            > "$output_file" 2>&1
        status=$?
        set -e

        [[ $status -eq 70 ]] ||
            fail "invalid review-only synthesis must use agent/backend-failure status 70, got $status"
        assert_contains "$(cat "$output_file")" "review-only synthesis" \
            "review-only validation failure must explain the contract breach"
    done
    pass "review-only rejects missing sections and claimed fixes"
}

test_pre_existing_findings_remain_report_only_in_both_modes() {
    local mode target custom_prompt output_file state_dir synthesis status expected_status

    for mode in review-only apply-fixes; do
        target="$TEST_ROOT/$mode-pre-existing-target"
        custom_prompt="$TEST_ROOT/$mode-pre-existing-criteria.md"
        output_file="$TEST_ROOT/$mode-pre-existing.out"
        make_target "$target"
        : > "$FAKE_AGENT_LOG"
        export FAKE_CUSTOM_CRITERIA="$mode pre-existing criteria"
        printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

        set +e
        FAKE_PRE_EXISTING_FINDING=1 PATH="$FAKE_BIN:$PATH" \
            "$SCRIPT_UNDER_TEST" "--$mode" --max-iters 1 --fixer codex \
            --prompt "$custom_prompt" claude codex "$target" \
            > "$output_file" 2>&1
        status=$?
        set -e
        [[ "$mode" == "review-only" ]] && expected_status=10 || expected_status=11
        [[ $status -eq $expected_status ]] ||
            fail "$mode findings must use status $expected_status, got $status:
$(cat "$output_file")"

        state_dir="$(find "$AR_STATE_ROOT" -type d \
            -name "$mode-pre-existing-target*" -print -quit)"
        synthesis="$state_dir/artifacts/iter1_4_synthesis.md"
        assert_contains "$(cat "$synthesis")" "Pre-existing issues noticed, not fixed" \
            "$mode must retain the PRE_EXISTING report-only section"
        assert_contains "$(cat "$synthesis")" "CLAUDE-2" \
            "$mode synthesis must carry the Claude PRE_EXISTING finding"
        assert_contains "$(cat "$synthesis")" "CODEX-2" \
            "$mode synthesis must carry the Codex PRE_EXISTING finding"
        [[ "$(jq -r '[.history[] | select(.phase == "phase_3") | (.result | fromjson).issue_scopes | to_entries[] | select(.value == "PRE_EXISTING")] | length' "$state_dir/tracking.json")" -eq 4 ]] ||
            fail "$mode must carry both PRE_EXISTING scopes through both meta-reviews"
        [[ "$(jq -r '.pre_existing_flagged' "$state_dir/tracking.json")" -eq 2 ]] ||
            fail "$mode must retain both PRE_EXISTING findings as flagged"
        [[ "$(jq -r '.pre_existing_fixed' "$state_dir/tracking.json")" -eq 0 ]] ||
            fail "$mode must not fix PRE_EXISTING findings without opt-in"
    done
    pass "PRE_EXISTING findings remain report-only in both execution modes"
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
            --max-iters 1 --fixer codex --prompt "$prompt" claude codex "$target" 2>&1)"
        status=$?
        set -e
        [[ $status -eq 64 ]] || fail "invalid prompt must use status 64, got $status: $prompt"
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
        --prompt "$custom_prompt" claude codex "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] || fail "a failed review agent must use status 70, got $status"
    [[ "$(grep -Ec '^(claude|codex)\|3\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
        fail "the workflow must not advance after a Phase 2 agent failure"
    state_dir="$(find "$AR_STATE_ROOT" -type d -name 'failing-review-target*' -print -quit)"
    artifact="$state_dir/artifacts/iter1_2_claude_on_codex.md"
    [[ -f "$artifact" ]] || fail "the failed agent artifact must be retained"
    assert_contains "$(cat "$artifact")" "simulated claude failure in phase 2" \
        "the retained artifact must contain failure diagnostics"
    assert_contains "$(cat "$output_file")" "Phase 2 slot-a (claude)" \
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
        --prompt "$custom_prompt" claude codex "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] || fail "a malformed review response must use status 70, got $status"
    assert_contains "$(cat "$output_file")" \
        "malformed stream-json transcript" \
        "the failure should explain that the structured response is invalid"
    [[ "$(grep -Ec '^(claude|codex)\|2\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
        fail "the workflow must not treat a malformed response as zero findings"
    pass "malformed review response stops instead of becoming zero findings"
}

test_denied_write_attempt_stops_with_raw_diagnostics() {
    local agent target custom_prompt output_file status state_dir raw_log
    local agent_label

    for agent in claude codex; do
        target="$TEST_ROOT/denied-write-$agent-target"
        custom_prompt="$TEST_ROOT/denied-write-$agent-criteria.md"
        output_file="$TEST_ROOT/denied-write-$agent.out"
        make_target "$target"

        : > "$FAKE_AGENT_LOG"
        export FAKE_CUSTOM_CRITERIA="Denied-write criteria for $agent"
        printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

        set +e
        FAKE_DENIED_WRITE_PHASE=2 FAKE_DENIED_WRITE_AGENT="$agent" \
            PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --max-iters 1 \
            --fixer codex --prompt "$custom_prompt" claude codex "$target" \
            > "$output_file" 2>&1
        status=$?
        set -e

        [[ $status -eq 77 ]] ||
            fail "a denied $agent write attempt must use status 77, got $status"
        if [[ "$agent" == "claude" ]]; then
            agent_label="slot-a (claude)"
        else
            agent_label="slot-b (codex)"
        fi
        assert_contains "$(cat "$output_file")" "Phase 2 $agent_label failed" \
            "the denied attempt must identify the failed phase and agent"
        state_dir="$(find "$AR_STATE_ROOT" -type d \
            -name "denied-write-$agent-target*" -print -quit)"
        if [[ "$agent" == "claude" ]]; then
            raw_log="$state_dir/artifacts/iter1_2_claude_on_codex.raw.log"
        else
            raw_log="$state_dir/artifacts/iter1_2_codex_on_claude.raw.log"
        fi
        assert_contains "$(cat "$raw_log")" "printf denied" \
            "the raw artifact must retain the denied $agent tool request"
        [[ "$(grep -Ec '^(claude|codex)\|3\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
            fail "the workflow must stop after a denied $agent write attempt"
        [[ "$(cat "$target/app.sh")" == $'committed state\nuser work in progress' ]] ||
            fail "a denied $agent write attempt must leave target evidence unchanged"
    done
    pass "Claude and Codex denied writes are fatal with raw diagnostics"
}

test_codex_turn_failure_is_not_a_write_violation() {
    local target="$TEST_ROOT/codex-turn-failure-target"
    local custom_prompt="$TEST_ROOT/codex-turn-failure-criteria.md"
    local output_file="$TEST_ROOT/codex-turn-failure.out"
    local status
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Codex turn failure criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    set +e
    FAKE_TURN_FAILURE_PHASE=2 PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] ||
        fail "ordinary Codex turn failure must use backend status 70, got $status"
    assert_contains "$(cat "$output_file")" "Codex reported a failed turn" \
        "ordinary turn failures must retain backend diagnostics"

    target="$TEST_ROOT/codex-mixed-failure-target"
    custom_prompt="$TEST_ROOT/codex-mixed-failure-criteria.md"
    output_file="$TEST_ROOT/codex-mixed-failure.out"
    make_target "$target"
    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Codex mixed failure criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    set +e
    FAKE_TURN_FAILURE_PHASE=2 FAKE_DENIED_WRITE_PHASE=2 \
        FAKE_DENIED_WRITE_AGENT=codex PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 77 ]] ||
        fail "denied-write evidence must take precedence over turn failure, got $status"
    pass "Codex turn failures remain distinct while boundary evidence takes precedence"
}

test_detected_target_write_stops_without_rollback() {
    local target="$TEST_ROOT/detected-write-target"
    local custom_prompt="$TEST_ROOT/detected-write-criteria.md"
    local output_file="$TEST_ROOT/detected-write.out"
    local status state_dir violation
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Detected-write criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    set +e
    FAKE_FORCE_REVIEW_WRITE_PHASE=2 PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --max-iters 1 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 77 ]] || fail "a detected target write must use status 77, got $status"
    assert_contains "$(cat "$output_file")" \
        "target changed during a read-only review phase" \
        "the boundary failure must explain that target evidence changed"
    state_dir="$(find "$AR_STATE_ROOT" -type d -name 'detected-write-target*' -print -quit)"
    violation="$state_dir/artifacts/iter1_phase_2_write_violation.json"
    [[ "$(jq -r '.phase' "$violation")" == "Phase 2" ]] ||
        fail "the write-violation artifact must identify the phase"
    [[ "$(jq -r '.automatically_reverted' "$violation")" == "false" ]] ||
        fail "the write-violation artifact must record the no-rollback policy"
    [[ "$(cat "$target/app.sh")" == $'committed state\nuser work in progress\ndetected review-phase write by claude' ]] ||
        fail "detected agent writes must not trigger a destructive rollback"
    [[ "$(grep -Ec '^(claude|codex)\|3\|' "$FAKE_AGENT_LOG")" -eq 0 ]] ||
        fail "the workflow must stop after detecting a review-phase write"
    pass "detected target write is fatal and is not rolled back"
}

test_fixer_failure_does_not_start_another_iteration() {
    local target="$TEST_ROOT/failing-fixer-target"
    local custom_prompt="$TEST_ROOT/failing-fixer-criteria.md"
    local output_file="$TEST_ROOT/failing-fixer.out"
    local status tracking
    make_target "$target"

    : > "$FAKE_AGENT_LOG"
    export FAKE_CUSTOM_CRITERIA="Failing-fixer criteria"
    printf '%s\n' "$FAKE_CUSTOM_CRITERIA" > "$custom_prompt"

    set +e
    FAKE_FAIL_PHASE=4 FAKE_FAIL_AGENT=codex PATH="$FAKE_BIN:$PATH" \
        "$SCRIPT_UNDER_TEST" --max-iters 2 --fixer codex \
        --prompt "$custom_prompt" claude codex "$target" > "$output_file" 2>&1
    status=$?
    set -e

    [[ $status -eq 70 ]] || fail "a failed Phase 4 fixer must use status 70, got $status"
    [[ "$(grep -c '^codex|4|' "$FAKE_AGENT_LOG")" -eq 1 ]] ||
        fail "a failed fixer must not start another review iteration"
    tracking="$(find "$AR_STATE_ROOT" -type f -path \
        '*failing-fixer-target*/tracking.json' -exec cat {} \;)"
    [[ "$(jq -r '.status' <<< "$tracking")" == "agent_failed" ]] ||
        fail "fixer failure must remain visible in tracking state"
    pass "fixer failure stops without starting another iteration"
}

test_custom_prompt_is_additive_and_review_phases_are_read_only
test_claude_fixer_is_writable_without_prompt_leakage
test_review_only_phase_4_is_read_only_and_preserves_target
test_apply_fixes_authorizes_only_phase_4_and_records_mode
test_review_only_runs_all_phases_when_phase_1_is_clean
test_apply_fixes_clean_phase_1_exits_clean
test_review_only_rejects_noncompliant_synthesis
test_pre_existing_findings_remain_report_only_in_both_modes
test_invalid_prompts_fail_before_agent_invocation
test_review_agent_failure_stops_with_diagnostics
test_malformed_review_response_stops_the_workflow
test_denied_write_attempt_stops_with_raw_diagnostics
test_codex_turn_failure_is_not_a_write_violation
test_detected_target_write_stops_without_rollback
test_fixer_failure_does_not_start_another_iteration

echo "1..$tests_run"
