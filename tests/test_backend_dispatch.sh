#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AR_STATE_ROOT="$TEST_ROOT/state"

# shellcheck source=../adversarial_review.sh
source "$SCRIPT_DIR/adversarial_review.sh"

tests_run=0

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message
expected:
$expected
actual:
$actual"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$message
missing: $needle"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "$message
unexpected: $needle"
}

assert_starts_with() {
    local haystack="$1"
    local prefix="$2"
    local message="$3"
    [[ "$haystack" == "$prefix"* ]] || fail "$message
expected prefix:
$prefix
actual:
$haystack"
}

pass() {
    tests_run=$((tests_run + 1))
    echo "ok $tests_run - $1"
}

run_claude() {
    printf '%s\n' "$*" > "$TEST_ROOT/claude.args"
    local scratch="${@: -1}"
    printf '%s' "$scratch" > "$TEST_ROOT/claude.scratch"
    if [[ -n "$scratch" && -d "$scratch" ]]; then
        echo present > "$TEST_ROOT/claude.scratch.present"
    else
        rm -f "$TEST_ROOT/claude.scratch.present"
    fi
    printf '%s\n' 'Claude response' > "$2"
    printf '%s\n' '{"type":"result"}' > "${2%.md}.raw.log"
}

run_codex() {
    printf '%s\n' "$*" > "$TEST_ROOT/codex.args"
    local scratch="${@: -1}"
    printf '%s' "$scratch" > "$TEST_ROOT/codex.scratch"
    if [[ -n "$scratch" && -d "$scratch" ]]; then
        echo present > "$TEST_ROOT/codex.scratch.present"
    else
        rm -f "$TEST_ROOT/codex.scratch.present"
    fi
    printf '%s\n' 'Codex response' > "$2"
    printf '%s\n' '{"type":"turn.completed"}' > "${2%.md}.raw.log"
}

audit_claude_review_transcript() {
    printf '%s\n' "$1" > "$TEST_ROOT/claude.audit"
    [[ "${FAIL_AUDIT:-}" != "claude" ]]
}

audit_codex_review_transcript() {
    printf '%s\n' "$1" > "$TEST_ROOT/codex.audit"
    [[ "${FAIL_AUDIT:-}" != "codex" ]]
}

test_read_only_claude_dispatches_and_audits() {
    local output_file="$TEST_ROOT/claude.md"
    local working_dir="$TEST_ROOT/target"
    mkdir -p "$working_dir"

    run_backend "claude" "review prompt" "$output_file" "$working_dir" \
        "read-only" "phase_2"

    assert_starts_with \
        "$(cat "$TEST_ROOT/claude.args")" \
        "review prompt $output_file $working_dir false $REVIEW_AVAILABLE_TOOLS $REVIEW_ALLOWED_TOOLS phase_2 " \
        "read-only Claude dispatch should retain its restricted tool contract"
    [[ -f "$TEST_ROOT/claude.scratch.present" ]] ||
        fail "read-only Claude dispatch should receive a scratch root that exists during the call"
    assert_eq "${output_file%.md}.raw.log" \
        "$(cat "$TEST_ROOT/claude.audit")" \
        "read-only Claude dispatch should audit its raw transcript"
    [[ ! -d "$(cat "$TEST_ROOT/claude.scratch")" ]] ||
        fail "read-only Claude dispatch scratch root should be removed once run_backend returns"
    pass "read-only Claude dispatches and audits"
}

test_read_only_codex_dispatches_and_audits() {
    local output_file="$TEST_ROOT/codex.md"
    local working_dir="$TEST_ROOT/target"
    mkdir -p "$working_dir"

    run_backend "codex" "review prompt" "$output_file" "$working_dir" \
        "read-only" "phase_3"

    assert_starts_with \
        "$(cat "$TEST_ROOT/codex.args")" \
        "review prompt $output_file $working_dir read-only phase_3 " \
        "read-only Codex dispatch should retain its sandbox contract"
    [[ -f "$TEST_ROOT/codex.scratch.present" ]] ||
        fail "read-only Codex dispatch should receive a scratch root that exists during the call"
    assert_eq "${output_file%.md}.raw.log" \
        "$(cat "$TEST_ROOT/codex.audit")" \
        "read-only Codex dispatch should audit its raw transcript"
    [[ ! -d "$(cat "$TEST_ROOT/codex.scratch")" ]] ||
        fail "read-only Codex dispatch scratch root should be removed once run_backend returns"
    pass "read-only Codex dispatches and audits"
}

test_workspace_write_dispatches_without_review_audits() {
    local claude_output="$TEST_ROOT/claude-write.md"
    local codex_output="$TEST_ROOT/codex-write.md"
    local working_dir="$TEST_ROOT/target"
    rm -f "$TEST_ROOT/claude.audit" "$TEST_ROOT/codex.audit"

    run_backend "claude" "fix prompt" "$claude_output" "$working_dir" \
        "workspace-write" "phase_4"
    assert_eq "fix prompt $claude_output $working_dir true   phase_4 " \
        "$(cat "$TEST_ROOT/claude.args")" \
        "writable Claude dispatch should enable its existing write mode"
    assert_eq "" "$(cat "$TEST_ROOT/claude.scratch")" \
        "writable Claude dispatch must not receive a scratch root"
    [[ ! -e "$TEST_ROOT/claude.audit" ]] ||
        fail "writable Claude dispatch must not run the review audit"

    run_backend "codex" "fix prompt" "$codex_output" "$working_dir" \
        "workspace-write" "phase_4"
    assert_eq "fix prompt $codex_output $working_dir workspace-write phase_4 " \
        "$(cat "$TEST_ROOT/codex.args")" \
        "writable Codex dispatch should enable its existing sandbox mode"
    assert_eq "" "$(cat "$TEST_ROOT/codex.scratch")" \
        "writable Codex dispatch must not receive a scratch root"
    [[ ! -e "$TEST_ROOT/codex.audit" ]] ||
        fail "writable Codex dispatch must not run the review audit"
    pass "workspace-write dispatches without review audits"
}

test_read_only_audit_failures_are_fatal_and_preserve_raw_logs() {
    local backend backend_label backend_output output_file status

    for backend in claude codex; do
        output_file="$TEST_ROOT/$backend-audit-failure.md"
        backend_label="${backend^}"
        FAIL_AUDIT="$backend"
        set +e
        backend_output="$(run_backend "$backend" "review prompt" "$output_file" \
            "$TEST_ROOT/target" "read-only" "phase_1" 2>&1)"
        status=$?
        set -e
        unset FAIL_AUDIT

        assert_eq "65" "$status" \
            "$backend audit failure should be fatal"
        assert_contains "$backend_output" "$backend_label exited with code 65" \
            "$backend audit failure should retain its exit diagnostic"
        assert_not_contains "$backend_output" "Complete" \
            "$backend audit failure must not be reported as complete"
        [[ -s "${output_file%.md}.raw.log" ]] ||
            fail "$backend audit failure should preserve the raw transcript"
    done
    pass "read-only audit failures are fatal and preserve raw logs"
}

test_read_only_dry_run_skips_transcript_audits() {
    rm -f "$TEST_ROOT/claude.audit" "$TEST_ROOT/codex.audit"
    DRY_RUN=1

    run_backend "claude" "review prompt" "$TEST_ROOT/claude-dry.md" \
        "$TEST_ROOT/target" "read-only" "phase_1"
    run_backend "codex" "review prompt" "$TEST_ROOT/codex-dry.md" \
        "$TEST_ROOT/target" "read-only" "phase_1"

    DRY_RUN=0
    [[ ! -e "$TEST_ROOT/claude.audit" ]] ||
        fail "dry-run Claude dispatch must not audit a nonexistent transcript"
    [[ ! -e "$TEST_ROOT/codex.audit" ]] ||
        fail "dry-run Codex dispatch must not audit a nonexistent transcript"
    pass "read-only dry-run skips transcript audits"
}

test_read_only_invocations_never_share_a_scratch_root() {
    local out_a="$TEST_ROOT/scratch-a.md"
    local out_b="$TEST_ROOT/scratch-b.md"
    local working_dir="$TEST_ROOT/target"
    mkdir -p "$working_dir"

    run_backend "claude" "review prompt" "$out_a" "$working_dir" \
        "read-only" "phase_1"
    local scratch_a
    scratch_a="$(cat "$TEST_ROOT/claude.scratch")"

    run_backend "codex" "review prompt" "$out_b" "$working_dir" \
        "read-only" "phase_1"
    local scratch_b
    scratch_b="$(cat "$TEST_ROOT/codex.scratch")"

    [[ -n "$scratch_a" && -n "$scratch_b" ]] ||
        fail "both read-only invocations should have received a scratch root"
    [[ "$scratch_a" != "$scratch_b" ]] ||
        fail "two read-only invocations in the same iteration must not share a scratch root"
    pass "read-only invocations never share a scratch root"
}

test_scratch_provisioning_failure_is_a_backend_failure_not_a_write_boundary_violation() {
    local output_file="$TEST_ROOT/scratch-failure.md"
    local working_dir="$TEST_ROOT/target"
    local status
    rm -f "$TEST_ROOT/claude.args"

    mktemp() {
        if [[ "${1:-}" == "-d" ]]; then
            return 1
        fi
        command mktemp "$@"
    }

    set +e
    backend_output="$(run_backend "claude" "review prompt" "$output_file" \
        "$working_dir" "read-only" "phase_1" 2>&1)"
    status=$?
    set -e
    unset -f mktemp

    assert_eq "$EXIT_AGENT_BACKEND_FAILURE" "$status" \
        "a scratch provisioning failure should be reported as an agent backend failure"
    [[ "$status" -ne "$PHASE_WRITE_BOUNDARY_VIOLATION" ]] ||
        fail "a scratch provisioning failure must never be reported as PHASE_WRITE_BOUNDARY_VIOLATION"
    assert_contains "$backend_output" "Failed to provision a scratch workspace" \
        "a scratch provisioning failure should explain what went wrong"
    [[ ! -e "$TEST_ROOT/claude.args" ]] ||
        fail "a scratch provisioning failure must not dispatch to the backend runner"
    pass "scratch provisioning failure is a backend failure, not a write-boundary violation"
}

test_unsupported_backend_mode_logs_diagnostic() {
    local backend_output status

    set +e
    backend_output="$(run_backend "unknown" "prompt" "$TEST_ROOT/unknown.md" \
        "$TEST_ROOT/target" "read-only" "phase_1" 2>&1)"
    status=$?
    set -e

    assert_eq "64" "$status" \
        "unsupported backend/mode combinations should retain their usage error"
    assert_contains "$backend_output" \
        "Unsupported backend/mode combination: unknown:read-only" \
        "unsupported backend/mode combinations should explain the failure"
    pass "unsupported backend/mode logs diagnostic"
}

test_read_only_claude_dispatches_and_audits
test_read_only_codex_dispatches_and_audits
test_workspace_write_dispatches_without_review_audits
test_read_only_audit_failures_are_fatal_and_preserve_raw_logs
test_read_only_dry_run_skips_transcript_audits
test_read_only_invocations_never_share_a_scratch_root
test_scratch_provisioning_failure_is_a_backend_failure_not_a_write_boundary_violation
test_unsupported_backend_mode_logs_diagnostic

echo "1..$tests_run"
