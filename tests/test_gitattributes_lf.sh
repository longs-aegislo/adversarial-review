#!/usr/bin/env bash
#
# Verifies that .gitattributes forces LF line endings for the shell entry
# point, lib/*.sh, and tests/test_*.sh regardless of the checkout side's
# core.autocrlf setting (e.g. Windows defaults to core.autocrlf=true),
# so WSL / Git Bash environments can execute these scripts unmodified.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

tests_run=0

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    tests_run=$((tests_run + 1))
    echo "ok $tests_run - $1"
}

assert_lf_no_crlf() {
    local file="$1"
    if grep -qU $'\r' "$file"; then
        fail "$file contains CR bytes after autocrlf=true checkout"
    fi
}

test_lf_enforced_under_autocrlf_true_checkout() {
    local clone_dir="$TEST_ROOT/clone"

    git clone -q --local --no-hardlinks "$SCRIPT_DIR" "$clone_dir"
    git -C "$clone_dir" config core.autocrlf true
    # Re-checkout so the newly-set autocrlf is applied by the checkout
    # filters, mirroring what a fresh Windows clone would do.
    git -C "$clone_dir" rm -q --cached -r . >/dev/null
    git -C "$clone_dir" checkout -f -q HEAD -- .

    assert_lf_no_crlf "$clone_dir/adversarial_review.sh"
    for f in "$clone_dir"/lib/*.sh; do
        assert_lf_no_crlf "$f"
    done
    for f in "$clone_dir"/tests/test_*.sh; do
        assert_lf_no_crlf "$f"
    done

    pass "shell entry point, lib, and test scripts stay LF under core.autocrlf=true"
}

test_scripts_execute_after_autocrlf_true_checkout() {
    local clone_dir="$TEST_ROOT/clone-exec"
    local out

    git clone -q --local --no-hardlinks "$SCRIPT_DIR" "$clone_dir"
    git -C "$clone_dir" config core.autocrlf true
    git -C "$clone_dir" rm -q --cached -r . >/dev/null
    git -C "$clone_dir" checkout -f -q HEAD -- .
    chmod +x "$clone_dir/adversarial_review.sh"

    out="$(bash "$clone_dir/adversarial_review.sh" --help 2>&1)" ||
        fail "adversarial_review.sh --help must run cleanly after an autocrlf=true checkout"
    [[ "$out" == *"USAGE:"* ]] ||
        fail "adversarial_review.sh --help output looks wrong: $out"

    out="$(bash "$clone_dir/tests/test_response_analyzer.sh" 2>&1)" ||
        fail "tests/test_response_analyzer.sh must run cleanly after an autocrlf=true checkout:
$out"

    pass "CLI entry point and a test entry point run under bash after autocrlf=true checkout"
}

test_lf_enforced_under_autocrlf_true_checkout
test_scripts_execute_after_autocrlf_true_checkout

echo "1..$tests_run"
