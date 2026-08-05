#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_RUNNER="$SCRIPT_DIR/.agents/skills/adversarial-review/scripts/run-review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"
for utility in bash cat git dirname mktemp rm sed tail awk; do
    ln -s "$(command -v "$utility")" "$TEST_BIN/$utility"
done
ln -s "$(type -P true)" "$TEST_BIN/true"
if command -v jq >/dev/null 2>&1; then
    ln -s "$(command -v jq)" "$TEST_BIN/jq"
elif [[ -x /tmp/adversarial-review-jq ]]; then
    ln -s /tmp/adversarial-review-jq "$TEST_BIN/jq"
else
    echo "not ok - jq is required for Skill scenario tests" >&2
    exit 1
fi
if command -v timeout >/dev/null 2>&1; then
    ln -s "$(command -v timeout)" "$TEST_BIN/timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    ln -s "$(command -v gtimeout)" "$TEST_BIN/gtimeout"
else
    echo "not ok - a timeout command is required for Skill scenario tests" >&2
    exit 1
fi

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
    git -C "$target" config user.name "Skill Scenario Test"
    git -C "$target" config user.email "skill-scenario@example.com"
    printf '%s\n' 'committed' > "$target/app.sh"
    git -C "$target" add app.sh
    git -C "$target" commit -qm initial
    printf '%s\n' 'committed' 'review me' > "$target/app.sh"
}

make_fake_cli() {
    local fake_cli="$1"
    cat > "$fake_cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    if [[ "${FAKE_CLI_UNSUPPORTED_SLOTS:-false}" == "true" ]]; then
        printf '%s\n' 'Usage: adversarial_review.sh --target-dir DIR --dry-run --review-only --result-file FILE'
        exit 0
    fi
    printf '%s\n' 'Usage: adversarial_review.sh --slot-a AGENT --slot-b AGENT --target-dir DIR --dry-run --review-only --result-file FILE'
    exit 0
fi

printf '<%s>' "$@" >> "${FAKE_COMMAND_LOG:?}"
printf '\n' >> "$FAKE_COMMAND_LOG"

result_file=""
target_dir=""
base_ref=""
slot_a=""
slot_b=""
dry_run=false
previous=""
for argument in "$@"; do
    [[ "$previous" == "--result-file" ]] && result_file="$argument"
    [[ "$previous" == "--target-dir" ]] && target_dir="$argument"
    [[ "$previous" == "--base" ]] && base_ref="$argument"
    [[ "$previous" == "--slot-a" ]] && slot_a="$argument"
    [[ "$previous" == "--slot-b" ]] && slot_b="$argument"
    [[ "$argument" == "--dry-run" ]] && dry_run=true
    previous="$argument"
done

if [[ "$dry_run" == "true" ]]; then
    cat > "$result_file" <<JSON
{"schema_version":1,"target_repo":{"path":"$target_dir"},"reviewers":{"slot_a":"$slot_a","slot_b":"$slot_b"},"scope":{"kind":"base","requested_base_ref":"$base_ref","resolved_base_commit":"abc"},"execution":{"mode":"review-only","dry_run":true,"review_executed":false},"termination":{"category":"incomplete-review","reason":"max-iterations","exit_code":12},"paths":{"artifacts_dir":"/tmp/artifacts","final_synthesis_artifact":null}}
JSON
    scope_count="${FAKE_SCOPE_COUNT:-1}"
    printf '[INFO] Files in scope (%s):\n' "$scope_count"
    [[ "$scope_count" == "0" ]] || printf '%s\n' '  app.sh'
    printf '%s\n' '[INFO] Execution mode: review-only'
    exit 12
fi

category="${FAKE_RESULT_CATEGORY:-clean}"
synthesis="/tmp/artifacts/iter1_4_synthesis.md"
cat > "$result_file" <<JSON
{"schema_version":1,"target_repo":{"path":"$target_dir"},"reviewers":{"slot_a":"$slot_a","slot_b":"$slot_b"},"scope":{"kind":"base","requested_base_ref":"$base_ref","resolved_base_commit":"abc"},"execution":{"mode":"review-only","dry_run":false,"review_executed":true},"termination":{"category":"$category","reason":"$category","exit_code":0},"counts":{"findings":{"in_scope":2,"pre_existing":1}},"paths":{"artifacts_dir":"/tmp/artifacts","final_synthesis_artifact":"$synthesis"}}
JSON
[[ "$category" == "clean" ]] && exit 0
exit 10
EOF
    chmod +x "$fake_cli"
}

make_fake_backend() {
    local backend="$1"
    local authenticated="${2:-true}"
    cat > "$TEST_BIN/$backend" <<EOF
#!/usr/bin/env bash
printf '%s %s\\n' '$backend' "\$*" >> "\${FAKE_BACKEND_LOG:?}"
if [[ "\$*" == 'auth status' || "\$*" == 'login status' ]]; then
    [[ '$authenticated' == 'true' ]]
    exit
fi
exit 99
EOF
    chmod +x "$TEST_BIN/$backend"
}

run_scenario() {
    local name="$1"
    local category="$2"
    local target="$TEST_ROOT/$name-target"
    local fake_cli="$TEST_ROOT/$name-cli"
    local output="$TEST_ROOT/$name.out"
    local command_log="$TEST_ROOT/$name.commands"
    local status

    make_target "$target"
    make_fake_cli "$fake_cli"
    rm -f "$TEST_BIN/claude" "$TEST_BIN/codex"
    [[ "${SCENARIO_CLAUDE_AVAILABLE:-true}" == "false" ]] ||
        make_fake_backend claude "${SCENARIO_CLAUDE_AUTH:-true}"
    [[ "${SCENARIO_CODEX_AVAILABLE:-true}" == "false" ]] ||
        make_fake_backend codex "${SCENARIO_CODEX_AUTH:-true}"
    set +e
    (
        cd "$target"
        PATH="$TEST_BIN" FAKE_COMMAND_LOG="$command_log" FAKE_BACKEND_LOG="$TEST_ROOT/$name.backends" FAKE_RESULT_CATEGORY="$category" \
            FAKE_CLI_UNSUPPORTED_SLOTS="${SCENARIO_UNSUPPORTED_SLOTS:-false}" \
            FAKE_SCOPE_COUNT="${SCENARIO_SCOPE_COUNT:-1}" \
            "$SKILL_RUNNER" --cli "${SCENARIO_CLI:-$fake_cli}" ${SCENARIO_SLOT_ARGS:-}
    ) > "$output" 2>&1
    status=$?
    set -e

    SCENARIO_STATUS=$status
    SCENARIO_OUTPUT="$(cat "$output")"
    SCENARIO_COMMANDS="$(cat "$command_log" 2>/dev/null || true)"
    SCENARIO_TARGET="$target"
}

test_same_model_redundancy() {
    local backend="$1"
    local unavailable_backend="$2"
    local scenario_name="$backend-only"

    if [[ "$unavailable_backend" == "claude" ]]; then
        SCENARIO_CLAUDE_AVAILABLE=false SCENARIO_SLOT_ARGS="--slot-a $backend --slot-b $backend" \
            run_scenario "$scenario_name" clean
    else
        SCENARIO_CODEX_AVAILABLE=false SCENARIO_SLOT_ARGS="--slot-a $backend --slot-b $backend" \
            run_scenario "$scenario_name" clean
    fi

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "intentional $backend redundancy should be supported"
    assert_contains "$SCENARIO_OUTPUT" "Reviewer slots: $backend, $backend" \
        "explicit $backend slots should be selected"
    assert_contains "$SCENARIO_OUTPUT" "lower review diversity" \
        "same-model redundancy must disclose reduced diversity"
    assert_selected_commands "$SCENARIO_TARGET" "$backend" "$backend"
    pass "explicit $backend-only redundancy preserves slots with a diversity warning"
}

test_auth_failure_stops_before_review() {
    SCENARIO_CODEX_AUTH=false run_scenario codex-auth-failure clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "authentication failure should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "Codex authentication check failed" \
        "failed authentication should identify the backend"
    [[ ! -s "$TEST_ROOT/codex-auth-failure.commands" ]] ||
        fail "authentication failure must not invoke the review CLI"
    pass "authentication failure stops before any review invocation"
}

test_missing_backend_stops_before_review() {
    SCENARIO_CODEX_AVAILABLE=false run_scenario missing-codex clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "missing backend should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "missing Agent backend executable: codex" \
        "missing backend should be named"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "missing backend must not invoke the review CLI"
    pass "missing backend executable stops before any review invocation"
}

test_missing_cli_stops_before_review() {
    SCENARIO_CLI="$TEST_ROOT/not-installed/adversarial_review.sh" run_scenario missing-cli clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "missing CLI should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "CLI is not executable" "missing CLI should be explained"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "missing CLI must not start a review"
    pass "missing CLI executable stops before any review invocation"
}

test_missing_jq_stops_before_review() {
    mv "$TEST_BIN/jq" "$TEST_BIN/jq.saved"
    run_scenario missing-jq clean
    mv "$TEST_BIN/jq.saved" "$TEST_BIN/jq"

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "missing jq should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "missing dependency: jq" "missing jq should be explained"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "missing jq must not invoke the review CLI"
    pass "missing jq stops before any review invocation"
}

test_missing_timeout_stops_before_review() {
    local timeout_name="timeout"
    [[ -e "$TEST_BIN/timeout" ]] || timeout_name="gtimeout"
    mv "$TEST_BIN/$timeout_name" "$TEST_BIN/$timeout_name.saved"
    run_scenario missing-timeout clean
    mv "$TEST_BIN/$timeout_name.saved" "$TEST_BIN/$timeout_name"

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "missing timeout should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "missing timeout support" "missing timeout should be explained"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "missing timeout must not invoke the review CLI"
    pass "missing timeout support stops before any review invocation"
}

test_incompatible_timeout_stops_before_review() {
    local timeout_name="timeout"
    [[ -e "$TEST_BIN/timeout" ]] || timeout_name="gtimeout"
    mv "$TEST_BIN/$timeout_name" "$TEST_BIN/$timeout_name.saved"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$TEST_BIN/$timeout_name"
    chmod +x "$TEST_BIN/$timeout_name"
    run_scenario incompatible-timeout clean
    rm -f "$TEST_BIN/$timeout_name"
    mv "$TEST_BIN/$timeout_name.saved" "$TEST_BIN/$timeout_name"

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "incompatible timeout should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "incompatible timeout support" \
        "incompatible timeout should be explained"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "incompatible timeout must not invoke the review CLI"
    pass "incompatible timeout stops before any review invocation"
}

test_non_gnu_compatible_timeout_is_accepted() {
    local timeout_name="timeout"
    [[ -e "$TEST_BIN/timeout" ]] || timeout_name="gtimeout"
    mv "$TEST_BIN/$timeout_name" "$TEST_BIN/$timeout_name.saved"
    printf '%s\n' '#!/usr/bin/env bash' 'shift' '"$@"' > "$TEST_BIN/$timeout_name"
    chmod +x "$TEST_BIN/$timeout_name"
    run_scenario compatible-timeout clean
    rm -f "$TEST_BIN/$timeout_name"
    mv "$TEST_BIN/$timeout_name.saved" "$TEST_BIN/$timeout_name"

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "CLI-compatible non-GNU timeout should be accepted"
    pass "CLI-compatible non-GNU timeout passes preflight"
}

test_unsupported_cli_slots_stop_before_review() {
    SCENARIO_UNSUPPORTED_SLOTS=true run_scenario unsupported-slots clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "unsupported CLI slots should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "does not support required option: --slot-a" \
        "unsupported slot contract should be explained"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "unsupported CLI must not start a review"
    pass "unsupported CLI reviewer slots stop before any review invocation"
}

assert_selected_commands() {
    local target="$1"
    local slot_a="${2:-claude}"
    local slot_b="${3:-codex}"
    local dry_command real_command
    dry_command="$(sed -n '1p' <<< "$SCENARIO_COMMANDS")"
    real_command="$(sed -n '2p' <<< "$SCENARIO_COMMANDS")"

    assert_contains "$dry_command" "<--dry-run><--review-only><--base><HEAD><--slot-a><$slot_a><--slot-b><$slot_b><--target-dir><$target><--result-file>" \
        "dry-run should use the complete explicit command contract"
    assert_contains "$real_command" "<--review-only><--base><HEAD><--slot-a><$slot_a><--slot-b><$slot_b><--target-dir><$target><--result-file>" \
        "real review should preserve the previewed command contract"
    [[ "$real_command" != *"<--dry-run>"* ]] || fail "real review must not retain --dry-run"
}

test_empty_scope_stops_before_real_review() {
    SCENARIO_SCOPE_COUNT=0 run_scenario empty clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "empty scope should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "empty or invalid Review Scope" \
        "empty scope should explain why the workflow stopped"
    [[ "$(wc -l <<< "$SCENARIO_COMMANDS" | tr -d ' ')" == "1" ]] ||
        fail "empty scope must not start a real review"
    pass "empty dry-run scope stops before real Agent calls"
}

test_discovers_cli_from_skill_repository() {
    local target="$TEST_ROOT/discovery-target"
    local tool_repo="$TEST_ROOT/discovery-tool"
    local runner_dir="$tool_repo/.agents/skills/adversarial-review/scripts"
    local output="$TEST_ROOT/discovery.out"
    local command_log="$TEST_ROOT/discovery.commands"
    local status

    make_target "$target"
    mkdir -p "$runner_dir"
    cp "$SKILL_RUNNER" "$runner_dir/run-review.sh"
    chmod +x "$runner_dir/run-review.sh"
    make_fake_cli "$tool_repo/adversarial_review.sh"
    make_fake_backend claude true
    make_fake_backend codex true

    set +e
    (
        cd "$target"
        PATH="$TEST_BIN" FAKE_COMMAND_LOG="$command_log" FAKE_BACKEND_LOG="$TEST_ROOT/discovery.backends" \
            "$runner_dir/run-review.sh"
    ) > "$output" 2>&1
    status=$?
    set -e

    [[ $status -eq 0 ]] || fail "repository-relative CLI discovery should succeed"
    assert_contains "$(cat "$output")" "Review result: clean" \
        "discovered CLI should complete the review"
    [[ "$(wc -l < "$command_log" | tr -d ' ')" == "2" ]] ||
        fail "discovered CLI should receive dry-run and real invocations"
    pass "adapter discovers the CLI from the Skill repository root"
}

test_explicit_clean_review() {
    run_scenario clean clean

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "clean scenario should succeed"
    assert_contains "$SCENARIO_OUTPUT" "Target Repo: $SCENARIO_TARGET" \
        "preview should identify the current Target Repo"
    assert_contains "$SCENARIO_OUTPUT" "Baseline: HEAD" \
        "preview should identify the baseline"
    assert_contains "$SCENARIO_OUTPUT" "Reviewer slots: claude, codex" \
        "preview should identify reviewer slots"
    assert_contains "$SCENARIO_OUTPUT" "Execution mode: review-only" \
        "explicit review should default to review-only"
    assert_contains "$SCENARIO_OUTPUT" "Review Scope (1): app.sh" \
        "dry-run scope should be shown before the real review"
    assert_contains "$SCENARIO_OUTPUT" "Review result: clean" \
        "clean machine result should be explained"
    assert_contains "$SCENARIO_OUTPUT" "Synthesis: /tmp/artifacts/iter1_4_synthesis.md" \
        "clean result should expose the final Synthesis"
    assert_contains "$SCENARIO_OUTPUT" "Artifacts: /tmp/artifacts" \
        "clean result should expose Artifacts"
    assert_selected_commands "$SCENARIO_TARGET"
    pass "explicit clean review previews scope and consumes the machine result"
}

test_explicit_findings_remaining_review() {
    run_scenario findings review-only-findings-remain

    [[ $SCENARIO_STATUS -eq 10 ]] || fail "findings scenario should preserve the review exit status"
    assert_contains "$SCENARIO_OUTPUT" "Review result: Findings remaining (in scope: 2, pre-existing: 1)" \
        "remaining findings should be distinguished from clean"
    assert_contains "$SCENARIO_OUTPUT" "Synthesis: /tmp/artifacts/iter1_4_synthesis.md" \
        "findings result should expose the final Synthesis"
    assert_contains "$SCENARIO_OUTPUT" "Artifacts: /tmp/artifacts" \
        "findings result should expose Artifacts"
    assert_selected_commands "$SCENARIO_TARGET"
    pass "explicit findings review reports Synthesis and Artifacts"
}

test_explicit_clean_review
test_explicit_findings_remaining_review
test_same_model_redundancy claude codex
test_same_model_redundancy codex claude
test_auth_failure_stops_before_review
test_missing_backend_stops_before_review
test_missing_cli_stops_before_review
test_missing_jq_stops_before_review
test_missing_timeout_stops_before_review
test_incompatible_timeout_stops_before_review
test_non_gnu_compatible_timeout_is_accepted
test_unsupported_cli_slots_stop_before_review
test_empty_scope_stops_before_real_review
test_discovers_cli_from_skill_repository

echo "1..$tests_run"
