#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

make_checkout() {
    local checkout="$1"
    mkdir -p "$checkout/scripts/git-hooks" "$checkout/nested/directory"
    git -C "$checkout" init -q
    cp "$REPO_ROOT/scripts/install-git-hooks.sh" "$checkout/scripts/install-git-hooks.sh"
    cp "$REPO_ROOT/scripts/git-hooks/pre-push" "$checkout/scripts/git-hooks/pre-push"
}

test_installs_from_a_subdirectory() {
    local checkout="$TEST_ROOT/subdirectory-checkout"
    local output
    make_checkout "$checkout"

    output="$(
        cd "$checkout/nested/directory"
        bash "$checkout/scripts/install-git-hooks.sh"
    )"

    [[ -x "$checkout/.git/hooks/pre-push" ]] ||
        fail "installer run from a subdirectory must use the checkout's real hooks directory"
    [[ ! -e "$checkout/nested/directory/.git/hooks/pre-push" ]] ||
        fail "installer must not interpret .git/hooks relative to the caller's subdirectory"
    [[ "$output" == *"installed $checkout/.git/hooks/pre-push"* ]] ||
        fail "installer should report the absolute installed hook path"

    pass "hook installer resolves the hooks directory independently of the caller's working directory"
}

test_refuses_to_overwrite_an_existing_hook() {
    local checkout="$TEST_ROOT/existing-hook-checkout"
    local hook output status
    make_checkout "$checkout"
    hook="$checkout/.git/hooks/pre-push"
    printf '%s\n' '#!/usr/bin/env bash' 'echo existing-hook' > "$hook"
    chmod +x "$hook"

    set +e
    output="$(cd "$checkout" && bash scripts/install-git-hooks.sh 2>&1)"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "installer must reject a conflicting existing hook"
    [[ "$output" == *"refusing to overwrite existing hook: $hook"* ]] ||
        fail "overwrite refusal should identify the preserved hook"
    [[ "$(tail -n 1 "$hook")" == "echo existing-hook" ]] ||
        fail "installer must leave a conflicting existing hook unchanged"

    pass "hook installer preserves a conflicting existing hook"
}

test_reinstalling_an_identical_hook_is_idempotent() {
    local checkout="$TEST_ROOT/idempotent-checkout"
    make_checkout "$checkout"

    (cd "$checkout" && bash scripts/install-git-hooks.sh >/dev/null)
    (cd "$checkout/nested" && bash "$checkout/scripts/install-git-hooks.sh" >/dev/null)
    cmp "$checkout/scripts/git-hooks/pre-push" "$checkout/.git/hooks/pre-push" >/dev/null ||
        fail "reinstalling should preserve the tracked hook bytes"

    pass "hook installer permits idempotent reinstallation"
}

test_refuses_to_follow_an_existing_hook_symlink() {
    local checkout="$TEST_ROOT/symlink-hook-checkout"
    local hook linked_file output status
    make_checkout "$checkout"
    hook="$checkout/.git/hooks/pre-push"
    linked_file="$checkout/external-hook"
    printf '%s\n' 'external hook contents' > "$linked_file"
    ln -s "$linked_file" "$hook"

    set +e
    output="$(cd "$checkout" && bash scripts/install-git-hooks.sh 2>&1)"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "installer must reject an existing hook symlink"
    [[ "$output" == *"refusing to replace non-file hook path: $hook"* ]] ||
        fail "symlink refusal should identify the preserved hook path"
    [[ "$(cat "$linked_file")" == "external hook contents" ]] ||
        fail "installer must not overwrite a hook symlink's target"

    pass "hook installer refuses to follow an existing hook symlink"
}

test_installs_from_a_subdirectory
test_refuses_to_overwrite_an_existing_hook
test_reinstalling_an_identical_hook_is_idempotent
test_refuses_to_follow_an_existing_hook_symlink

echo "1..$tests_run"
