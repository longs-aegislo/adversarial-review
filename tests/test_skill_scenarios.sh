#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_RUNNER="$SCRIPT_DIR/.agents/skills/adversarial-review/scripts/run-review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"
if command -v jq >/dev/null 2>&1; then
    ln -s "$(command -v jq)" "$TEST_BIN/jq"
elif [[ -x /tmp/adversarial-review-jq ]]; then
    ln -s /tmp/adversarial-review-jq "$TEST_BIN/jq"
else
    echo "not ok - jq is required for Skill scenario tests" >&2
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
    set +e
    (
        cd "$target"
        PATH="$TEST_BIN:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_RESULT_CATEGORY="$category" \
            FAKE_SCOPE_COUNT="${SCENARIO_SCOPE_COUNT:-1}" \
            "$SKILL_RUNNER" --cli "$fake_cli"
    ) > "$output" 2>&1
    status=$?
    set -e

    SCENARIO_STATUS=$status
    SCENARIO_OUTPUT="$(cat "$output")"
    SCENARIO_COMMANDS="$(cat "$command_log")"
    SCENARIO_TARGET="$target"
}

assert_selected_commands() {
    local target="$1"
    local dry_command real_command
    dry_command="$(sed -n '1p' <<< "$SCENARIO_COMMANDS")"
    real_command="$(sed -n '2p' <<< "$SCENARIO_COMMANDS")"

    assert_contains "$dry_command" "<--dry-run><--review-only><--base><HEAD><--slot-a><claude><--slot-b><codex><--target-dir><$target><--result-file>" \
        "dry-run should use the complete explicit command contract"
    assert_contains "$real_command" "<--review-only><--base><HEAD><--slot-a><claude><--slot-b><codex><--target-dir><$target><--result-file>" \
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
test_empty_scope_stops_before_real_review

echo "1..$tests_run"
