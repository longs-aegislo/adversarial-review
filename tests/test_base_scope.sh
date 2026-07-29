#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/adversarial_review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AR_STATE_ROOT="$TEST_ROOT/state"

# shellcheck source=../adversarial_review.sh
source "$SCRIPT_UNDER_TEST"

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

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
}

make_scoped_repo() {
    local repo="$1"
    init_repo "$repo"

    mkdir -p "$repo/src" "$repo/vendor" "$repo/dist"
    echo 'print("base")' > "$repo/src/app.py"
    echo 'export const unchanged = true;' > "$repo/src/unchanged.ts"
    echo '# base' > "$repo/README.md"
    git -C "$repo" add .
    git -C "$repo" commit -qm "base"
    git -C "$repo" branch base

    echo 'print("committed change")' > "$repo/src/app.py"
    echo 'export const feature = true;' > "$repo/src/feature.ts"
    echo '<?php echo "vendored";' > "$repo/vendor/bad.php"
    echo 'not reviewable' > "$repo/notes.md"
    git -C "$repo" add .
    git -C "$repo" commit -qm "feature"

    echo 'echo in-progress' > "$repo/work.sh"
    echo 'console.log("generated")' > "$repo/dist/generated.js"
    echo 'not reviewable either' > "$repo/untracked.md"
}

test_whole_directory_scan_is_unchanged() {
    local repo="$TEST_ROOT/whole-directory"
    make_scoped_repo "$repo"

    local actual
    actual="$(collect_file_list "$repo" "")"

    assert_eq $'src/app.py\nsrc/feature.ts\nsrc/unchanged.ts\nwork.sh' "$actual" \
        "whole-directory mode should retain the existing allowlist and exclusions"
    pass "whole-directory file collection remains unchanged"
}

test_base_scope_merges_committed_and_untracked_files() {
    local repo="$TEST_ROOT/base-scope"
    make_scoped_repo "$repo"

    local actual
    actual="$(collect_file_list "$repo" base)"

    assert_eq $'src/app.py\nsrc/feature.ts\nwork.sh' "$actual" \
        "base scope should contain only reviewable changed and untracked files"
    pass "base scope merges committed divergence and untracked work"
}

test_base_scope_includes_deleted_source_files() {
    local repo="$TEST_ROOT/deleted-source"
    make_scoped_repo "$repo"
    rm "$repo/src/unchanged.ts"

    local actual
    actual="$(collect_file_list "$repo" base)"

    assert_contains "$actual" 'src/unchanged.ts' \
        "base scope should retain the path of a deleted reviewable source file"
    pass "base scope includes deleted source files"
}

test_resolved_base_stays_stable_when_ref_moves() {
    local repo="$TEST_ROOT/stable-base"
    make_scoped_repo "$repo"
    local resolved_base
    resolved_base="$(git -C "$repo" rev-parse base)"
    git -C "$repo" branch -f base HEAD

    local actual
    actual="$(collect_file_list "$repo" "$resolved_base")"

    assert_eq $'src/app.py\nsrc/feature.ts\nwork.sh' "$actual" \
        "a resolved base commit should not drift when the symbolic ref moves"
    pass "resolved base remains stable when its ref moves"
}

test_base_scope_stays_within_git_subdirectory_target() {
    local repo="$TEST_ROOT/monorepo"
    local target="$repo/packages/app"
    init_repo "$repo"
    mkdir -p "$target/src" "$repo/packages/other"
    echo 'print("base")' > "$target/src/app.py"
    echo 'print("outside base")' > "$repo/packages/other/outside.py"
    git -C "$repo" add .
    git -C "$repo" commit -qm "base"
    git -C "$repo" branch base

    echo 'print("inside change")' > "$target/src/app.py"
    echo 'print("outside change")' > "$repo/packages/other/outside.py"
    echo 'echo inside work' > "$target/work.sh"

    local actual
    actual="$(collect_file_list "$target" base)"

    assert_eq $'src/app.py\nwork.sh' "$actual" \
        "base scope should be relative to and contained by a git subdirectory target"
    pass "base scope stays within a git subdirectory target"
}

test_recent_diff_respects_base_scope_filters() {
    local repo="$TEST_ROOT/recent-diff"
    make_scoped_repo "$repo"
    echo 'print("working tree change")' > "$repo/src/app.py"

    local actual
    actual="$(collect_recent_diff "$repo" 2 base)"

    assert_contains "$actual" 'diff --git a/src/app.py b/src/app.py' \
        "recent diff should include an in-scope tracked change"
    assert_contains "$actual" '=== NEW FILE: work.sh ===' \
        "recent diff should include an in-scope untracked source file"
    assert_not_contains "$actual" 'dist/generated.js' \
        "recent diff should exclude generated paths"
    assert_not_contains "$actual" 'untracked.md' \
        "recent diff should exclude disallowed extensions"
    pass "recent diff composes with base-scoped file filtering"
}

test_recent_diff_default_mode_filters_untracked_files() {
    local repo="$TEST_ROOT/default-recent-diff"
    init_repo "$repo"
    echo 'echo base' > "$repo/app.sh"
    git -C "$repo" add .
    git -C "$repo" commit -qm "base"
    echo 'echo in-progress' > "$repo/work.sh"
    echo 'not source code' > "$repo/random-notes.md"
    echo 'print("hidden source")' > "$repo/.hidden.py"

    local actual
    actual="$(collect_recent_diff "$repo" 2 "")"

    assert_contains "$actual" '=== NEW FILE: work.sh ===' \
        "default recent diff should include reviewable untracked source files"
    assert_not_contains "$actual" 'random-notes.md' \
        "default recent diff should exclude untracked files with disallowed extensions"
    assert_not_contains "$actual" '.hidden.py' \
        "default recent diff should apply the same hidden-path exclusion as source collection"
    pass "recent diff default mode filters untracked files like source collection"
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

test_cli_rejects_non_git_target() {
    local target="$TEST_ROOT/not-git"
    mkdir -p "$target"

    run_cli "$TEST_ROOT/not-git.out" --dry-run --base main "$target"

    [[ "$CLI_STATUS" -ne 0 ]] || fail "non-git base scope should fail"
    assert_contains "$CLI_OUTPUT" 'not a git working tree' \
        "non-git base scope should explain the failure"
    pass "CLI rejects --base for a non-git target"
}

test_cli_rejects_unknown_base() {
    local repo="$TEST_ROOT/bad-ref"
    init_repo "$repo"
    echo 'echo base' > "$repo/app.sh"
    git -C "$repo" add .
    git -C "$repo" commit -qm "base"

    run_cli "$TEST_ROOT/bad-ref.out" --dry-run --base does-not-exist "$repo"

    [[ "$CLI_STATUS" -ne 0 ]] || fail "unknown base ref should fail"
    assert_contains "$CLI_OUTPUT" 'does not resolve' \
        "unknown base ref should explain the failure"
    pass "CLI rejects an unknown base ref"
}

test_cli_rejects_empty_base_scope() {
    local repo="$TEST_ROOT/empty-scope"
    init_repo "$repo"
    echo 'echo base' > "$repo/app.sh"
    git -C "$repo" add .
    git -C "$repo" commit -qm "base"
    git -C "$repo" branch base

    run_cli "$TEST_ROOT/empty-scope.out" --dry-run --base base "$repo"

    [[ "$CLI_STATUS" -ne 0 ]] || fail "empty base scope should fail"
    assert_contains "$CLI_OUTPUT" 'No reviewable files differ from base' \
        "empty base scope should explain that there is nothing to review"
    pass "CLI rejects an empty base scope"
}

test_cli_ignores_ambient_base_ref() {
    local target="$TEST_ROOT/ambient-base"
    mkdir -p "$target"
    echo 'echo review me' > "$target/app.sh"

    set +e
    BASE_REF=does-not-exist "$SCRIPT_UNDER_TEST" --dry-run --max-iters 1 "$target" \
        > "$TEST_ROOT/ambient-base.out" 2>&1
    set -e
    local output
    output="$(cat "$TEST_ROOT/ambient-base.out")"

    assert_contains "$output" 'Scope: whole-directory' \
        "base mode should only be enabled by an explicit CLI flag"
    assert_not_contains "$output" 'Cannot use --base' \
        "an ambient BASE_REF should not affect existing invocations"
    pass "CLI ignores an ambient BASE_REF"
}

test_dry_run_reports_resolved_base_scope() {
    local repo="$TEST_ROOT/dry-run"
    make_scoped_repo "$repo"

    run_cli "$TEST_ROOT/dry-run.out" --dry-run --max-iters 1 --base base "$repo"

    assert_contains "$CLI_OUTPUT" 'Scope: base-scoped (base)' \
        "dry-run should identify base-scoped mode"
    assert_contains "$CLI_OUTPUT" 'Files in scope (3):' \
        "dry-run should report the resolved file count"
    assert_contains "$CLI_OUTPUT" 'src/feature.ts' \
        "dry-run should print the resolved file list"

    run_cli "$TEST_ROOT/status.out" --status "$repo"
    [[ "$CLI_STATUS" -eq 0 ]] || fail "status command should succeed after a scoped run"
    assert_contains "$CLI_OUTPUT" 'Scope:      base' \
        "status should surface the base ref persisted by the run"
    pass "dry-run reports the resolved scope and file list"
}

test_whole_directory_scan_is_unchanged
test_base_scope_merges_committed_and_untracked_files
test_base_scope_includes_deleted_source_files
test_resolved_base_stays_stable_when_ref_moves
test_base_scope_stays_within_git_subdirectory_target
test_recent_diff_respects_base_scope_filters
test_recent_diff_default_mode_filters_untracked_files
test_cli_rejects_non_git_target
test_cli_rejects_unknown_base
test_cli_rejects_empty_base_scope
test_cli_ignores_ambient_base_ref
test_dry_run_reports_resolved_base_scope

echo "1..$tests_run"
