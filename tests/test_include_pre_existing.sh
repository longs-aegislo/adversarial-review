#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/adversarial_review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AR_STATE_ROOT="$TEST_ROOT/state"

tests_run=0

fail() {
    echo "not ok - $1" >&2
    exit 1
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

pass() {
    tests_run=$((tests_run + 1))
    echo "ok $tests_run - $1"
}

run_cli() {
    local output_file="$1"
    shift
    set +e
    "$SCRIPT_UNDER_TEST" "$@" > "$output_file" 2>&1
    CLI_STATUS=$?
    set -e
    CLI_OUTPUT="$(cat "$output_file")"
}

make_target() {
    local target="$1"
    mkdir -p "$target"
    echo 'echo review me' > "$target/app.sh"
}

test_phase_4_defaults_to_in_scope_fixes_only() {
    local target="$TEST_ROOT/default-policy"
    make_target "$target"

    run_cli "$TEST_ROOT/default.out" --dry-run --max-iters 1 claude codex "$target"

    assert_contains "$CLI_OUTPUT" \
        'Phase 4 scope policy: fix IN_SCOPE findings; flag PRE_EXISTING findings without applying them' \
        "dry-run should expose the conservative Phase 4 policy"
    assert_not_contains "$CLI_OUTPUT" '--include-pre-existing enabled' \
        "the opt-in policy should not be active by default"
    pass "Phase 4 defaults to in-scope fixes only"
}

test_include_pre_existing_opts_phase_4_into_both_categories() {
    local target="$TEST_ROOT/include-policy"
    make_target "$target"

    run_cli "$TEST_ROOT/include.out" \
        --dry-run --max-iters 1 --include-pre-existing claude codex "$target"

    assert_contains "$CLI_OUTPUT" \
        'Phase 4 scope policy: fix IN_SCOPE and PRE_EXISTING findings (--include-pre-existing enabled)' \
        "dry-run should expose the explicit whole-repo cleanup policy"

    run_cli "$TEST_ROOT/status.out" --status claude codex "$target"
    assert_contains "$CLI_OUTPUT" 'Pre-existing fixes: included' \
        "status should retain the explicit Phase 4 scope policy"
    pass "--include-pre-existing opts Phase 4 into both categories"
}

test_ambient_environment_cannot_enable_pre_existing_fixes() {
    local target="$TEST_ROOT/ambient-policy"
    make_target "$target"

    set +e
    INCLUDE_PRE_EXISTING=1 "$SCRIPT_UNDER_TEST" --dry-run --max-iters 1 claude codex "$target" \
        > "$TEST_ROOT/ambient.out" 2>&1
    set -e
    local output
    output="$(cat "$TEST_ROOT/ambient.out")"

    assert_contains "$output" \
        'Phase 4 scope policy: fix IN_SCOPE findings; flag PRE_EXISTING findings without applying them' \
        "pre-existing fixes should require the explicit CLI opt-in"
    pass "ambient environment cannot enable pre-existing fixes"
}

test_phase_4_defaults_to_in_scope_fixes_only
test_include_pre_existing_opts_phase_4_into_both_categories
test_ambient_environment_cannot_enable_pre_existing_fixes

echo "1..$tests_run"
