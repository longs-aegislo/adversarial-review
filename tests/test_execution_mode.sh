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

    [[ $status -ne 0 ]] || fail "specifying both modes must exit non-zero"
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

    [[ $status -ne 0 ]] || fail "both modes with no slots/target must still exit non-zero"
    assert_contains "$output" "No slot-a backend specified" \
        "missing slot-a is reported first, before mode validation runs"
    pass "mode validation is reached only after required slot/target arguments are present"
}

test_review_only_mode_prints_no_migration_notice() {
    local target="$TEST_ROOT/review-only-target"
    local output
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --max-iters 1 --review-only claude codex "$target" 2>&1)" || true

    assert_not_contains "$output" "implicit" \
        "explicitly choosing --review-only must not print the migration notice"
    pass "--review-only alone runs without a migration notice"
}

test_apply_fixes_mode_prints_no_migration_notice() {
    local target="$TEST_ROOT/apply-fixes-target"
    local output
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --max-iters 1 --apply-fixes claude codex "$target" 2>&1)" || true

    assert_not_contains "$output" "implicit" \
        "explicitly choosing --apply-fixes must not print the migration notice"
    pass "--apply-fixes alone runs without a migration notice"
}

test_no_mode_prints_migration_notice() {
    local target="$TEST_ROOT/no-mode-target"
    local output
    make_target "$target"
    : > "$FAKE_AGENT_LOG"

    output="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT_UNDER_TEST" \
        --dry-run --max-iters 1 claude codex "$target" 2>&1)" || true

    assert_contains "$output" "implicit" \
        "omitting both mode flags must print a migration notice about the implicit default"
    pass "omitting both --review-only and --apply-fixes prints a migration notice"
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

    [[ $status -ne 0 ]] || fail "both modes must still exit non-zero even with a valid target"
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

    pass "management commands (--status et al.) are unaffected by mode validation"
}

test_both_modes_is_a_startup_error
test_both_modes_errors_before_dependency_check
test_review_only_mode_prints_no_migration_notice
test_apply_fixes_mode_prints_no_migration_notice
test_no_mode_prints_migration_notice
test_both_modes_error_fires_before_fixer_selection_and_agent_calls
test_management_commands_unaffected_by_mode_validation

echo "1..$tests_run"
