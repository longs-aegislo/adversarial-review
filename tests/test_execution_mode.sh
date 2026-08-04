#!/usr/bin/env bash
#
# Verifies the --review-only / --apply-fixes explicit execution-mode flags:
# mode validation happens before any dependency check or agent invocation.

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
missing: $needle
output:
$haystack"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "$message
unexpected: $needle
output:
$haystack"
}

make_target() {
    local target="$1"
    mkdir -p "$target"
    echo 'echo review me' > "$target/app.sh"
}

# Any invocation of these fakes counts as "an agent was called" for the
# purposes of asserting that mode validation runs before agent invocation.
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude called" >> "$FAKE_AGENT_LOG"
exit 1
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex called" >> "$FAKE_AGENT_LOG"
exit 1
EOF

chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/codex"

test_both_modes_is_a_startup_error() {
    local target="$TEST_ROOT/both-modes-target"
    local output status
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --apply-fixes claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 64 ]] || fail "specifying both modes must use invalid-invocation status 64, got $status"
    assert_contains "$output" "mutually exclusive" \
        "the error must explain the modes are mutually exclusive"
    [[ ! -s "$FAKE_AGENT_LOG" ]] ||
        fail "specifying both modes must not invoke any agent"
    pass "specifying both --review-only and --apply-fixes is a startup error before any agent runs"
}

test_both_modes_errors_before_dependency_check() {
    local output status

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --apply-fixes 2>&1)"
    status=$?
    set -e

    [[ $status -eq 64 ]] || fail "missing required arguments must use invalid-invocation status 64, got $status"
    assert_contains "$output" "No slot-a backend specified" \
        "missing slot-a is reported first, before mode validation runs"
    pass "mode validation is reached only after required slot/target arguments are present"
}

test_review_only_mode_prints_no_migration_notice() {
    local target="$TEST_ROOT/review-only-target"
    local output status
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --max-iters 1 --review-only claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "--review-only max-iterations must use incomplete-review status 12: $output"
    assert_contains "$output" "[DRY RUN]" \
        "--review-only must reach normal dry-run execution"
    assert_contains "$output" "Reached max iterations (1)" \
        "--review-only must complete the configured dry-run iteration"
    assert_not_contains "$output" "implicit" \
        "explicitly choosing --review-only must not print the migration notice"
    pass "--review-only alone runs without a migration notice"
}

test_apply_fixes_mode_prints_no_migration_notice() {
    local target="$TEST_ROOT/apply-fixes-target"
    local output status
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --max-iters 1 --apply-fixes claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "--apply-fixes max-iterations must use incomplete-review status 12: $output"
    assert_contains "$output" "[DRY RUN]" \
        "--apply-fixes must reach normal dry-run execution"
    assert_contains "$output" "Reached max iterations (1)" \
        "--apply-fixes must complete the configured dry-run iteration"
    assert_not_contains "$output" "implicit" \
        "explicitly choosing --apply-fixes must not print the migration notice"
    pass "--apply-fixes alone runs without a migration notice"
}

test_no_mode_prints_migration_notice() {
    local target="$TEST_ROOT/no-mode-target"
    local output status
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --max-iters 1 claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "implicit-mode max-iterations must use incomplete-review status 12: $output"
    assert_contains "$output" "[DRY RUN]" \
        "implicit mode must reach normal dry-run execution"
    assert_contains "$output" "Reached max iterations (1)" \
        "implicit mode must complete the configured dry-run iteration"
    assert_contains "$output" "implicit" \
        "omitting both mode flags must print a migration notice about the implicit default"
    pass "omitting both --review-only and --apply-fixes prints a migration notice"
}

test_help_distinguishes_dry_run_from_review_only() {
    local output

    output="$($SCRIPT_UNDER_TEST --help)"
    assert_contains "$output" "without calling Agents" \
        "--help must explain that dry-run does not call Agents"
    assert_contains "$output" "producing review conclusions; not a substitute" \
        "--help must explain that dry-run cannot substitute for review-only"
    pass "help distinguishes dry-run preview from a real review-only run"
}

test_both_modes_error_fires_before_fixer_selection_and_agent_calls() {
    local target="$TEST_ROOT/both-modes-valid-target"
    local output status
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --apply-fixes --fixer codex claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 64 ]] || fail "mode conflict must use invalid-invocation status 64, got $status"
    assert_contains "$output" "mutually exclusive" \
        "the mode-exclusivity error must fire"
    assert_not_contains "$output" "Phase 4 fixes will be implemented by" \
        "the mode-exclusivity check must run before fixer selection/dependency checks"
    [[ ! -s "$FAKE_AGENT_LOG" ]] ||
        fail "the mode-exclusivity error must fire before any agent is invoked"
    pass "mode validation runs before fixer selection, dependency checks, and any agent call"
}

test_management_commands_unaffected_by_mode_validation() {
    local target="$TEST_ROOT/status-target"
    local output status
    make_target "$target"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" --status claude codex "$target" 2>&1)"
    status=$?
    set -e
    [[ $status -eq 0 ]] || fail "--status must still succeed without any mode flag: $output"
    assert_not_contains "$output" "mutually exclusive" \
        "--status must not be affected by mode validation"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --review-only --apply-fixes --status claude codex "$target" 2>&1)"
    status=$?
    set -e
    [[ $status -eq 0 ]] || fail "--status must take priority over later mode validation: $output"
    assert_not_contains "$output" "mutually exclusive" \
        "--status must short-circuit before the mode-exclusivity check runs"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --status --max-iters invalid --timeout invalid \
        claude codex "$target" 2>&1)"
    status=$?
    set -e
    [[ $status -eq 0 ]] ||
        fail "--status must retain precedence over review-only numeric validation: $output"
    assert_not_contains "$output" "positive integer" \
        "management commands must ignore review-only numeric options as before"

    pass "management commands (--status et al.) are unaffected by mode validation"
}

test_open_circuit_uses_incomplete_review_status() {
    local target="$TEST_ROOT/open-circuit-target"
    local output status circuit_file circuit_tmp tracking_file
    make_target "$target"

    PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --circuit-status claude codex "$target" >/dev/null 2>&1
    circuit_file="$(find "$AR_STATE_ROOT" -path \
        '*open-circuit-target*/.circuit_breaker.json' -print -quit)"
    circuit_tmp="$TEST_ROOT/open-circuit.json"
    jq '.state = "OPEN" | .reason = "test circuit"' \
        "$circuit_file" > "$circuit_tmp"
    mv "$circuit_tmp" "$circuit_file"

    set +e
    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --apply-fixes claude codex "$target" 2>&1)"
    status=$?
    set -e

    [[ $status -eq 12 ]] || fail "open circuit must use incomplete-review status 12, got $status"
    assert_contains "$output" "Circuit breaker is OPEN" \
        "open-circuit output must identify the incomplete-review reason"
    tracking_file="$(find "$AR_STATE_ROOT" -path \
        '*open-circuit-target*/tracking.json' -print -quit)"
    [[ "$(jq -r '.status' "$tracking_file")" == "circuit_open" ]] ||
        fail "tracking must distinguish circuit-open from max-iterations"
    pass "open circuit uses incomplete-review status and remains distinguishable in tracking"
}

test_invalid_numeric_options_use_invalid_invocation_status() {
    local target="$TEST_ROOT/invalid-numeric-target"
    local option value output status
    make_target "$target"

    for option in --max-iters --timeout; do
        value=invalid
        set +e
        output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
            "$option" "$value" --apply-fixes claude codex "$target" 2>&1)"
        status=$?
        set -e
        [[ $status -eq 64 ]] ||
            fail "$option invalid value must use status 64, got $status"
        assert_contains "$output" "positive integer" \
            "$option invalid value must explain its numeric contract"
    done
    pass "invalid numeric options use invalid-invocation status"
}

test_both_modes_is_a_startup_error
test_both_modes_errors_before_dependency_check
test_review_only_mode_prints_no_migration_notice
test_apply_fixes_mode_prints_no_migration_notice
test_no_mode_prints_migration_notice
test_help_distinguishes_dry_run_from_review_only
test_both_modes_error_fires_before_fixer_selection_and_agent_calls
test_management_commands_unaffected_by_mode_validation
test_open_circuit_uses_incomplete_review_status
test_invalid_numeric_options_use_invalid_invocation_status

echo "1..$tests_run"
