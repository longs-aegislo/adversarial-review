#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_RUNNER="$SCRIPT_DIR/.agents/skills/adversarial-review/scripts/run-review.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"
for utility in bash cat git dirname grep mktemp rm sed sort tail awk; do
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

make_committed_feature_target() {
    local target="$1"

    make_target "$target"
    git -C "$target" checkout -qb main
    git -C "$target" add app.sh
    git -C "$target" commit -qm main-change
    git -C "$target" checkout -qb feature
    printf '%s\n' 'committed feature' > "$target/feature.sh"
    git -C "$target" add feature.sh
    git -C "$target" commit -qm feature-work
}

make_fake_cli() {
    local fake_cli="$1"
    cat > "$fake_cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    if [[ "${FAKE_CLI_UNSUPPORTED_SLOTS:-false}" == "true" ]]; then
        printf '%s\n' 'Usage: adversarial_review.sh --base REF --target-dir DIR --dry-run --review-only --result-file FILE'
        exit 0
    fi
    printf '%s\n' 'Usage: adversarial_review.sh --base REF --slot-a AGENT --slot-b AGENT --target-dir DIR --dry-run --review-only --result-file FILE'
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
    scope_files="${FAKE_SCOPE_FILES:-app.sh}"
    scope_count="${FAKE_SCOPE_COUNT:-1}"
    cat > "$result_file" <<JSON
{"schema_version":1,"target_repo":{"path":"$target_dir"},"reviewers":{"slot_a":"$slot_a","slot_b":"$slot_b"},"scope":{"kind":"base","requested_base_ref":"$base_ref","resolved_base_commit":"abc"},"execution":{"mode":"review-only","dry_run":true,"review_executed":false},"termination":{"category":"incomplete-review","reason":"max-iterations","exit_code":12},"paths":{"artifacts_dir":"/tmp/artifacts","final_synthesis_artifact":null}}
JSON
    printf '[INFO] Files in scope (%s):\n' "$scope_count"
    if [[ "$scope_count" == "1" ]]; then
        printf '  %s\n' "$scope_files"
    elif [[ -n "${FAKE_SCOPE_FILES:-}" ]]; then
        sed 's/^/  /' <<< "$scope_files"
    else
        scope_index=1
        while [[ "$scope_index" -le "$scope_count" ]]; do
            printf '  file-%s.sh\n' "$scope_index"
            scope_index=$((scope_index + 1))
        done
    fi
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
    local target="${SCENARIO_TARGET_OVERRIDE:-$TEST_ROOT/$name-target}"
    local fake_cli="$TEST_ROOT/$name-cli"
    local output="$TEST_ROOT/$name.out"
    local command_log="$TEST_ROOT/$name.commands"
    local status

    [[ -n "${SCENARIO_TARGET_OVERRIDE:-}" ]] || make_target "$target"
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
            FAKE_SCOPE_FILES="${SCENARIO_SCOPE_FILES:-app.sh}" \
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

test_committed_feature_branch_uses_default_branch_merge_base() {
    local target="$TEST_ROOT/committed-feature-target"

    make_committed_feature_target "$target"
    SCENARIO_TARGET_OVERRIDE="$target" SCENARIO_SCOPE_FILES=feature.sh run_scenario committed-feature clean

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "committed feature work should select a safe baseline"
    local merge_base
    merge_base="$(git -C "$target" merge-base HEAD main)"
    assert_contains "$SCENARIO_OUTPUT" "Baseline: $merge_base (merge-base of feature and main)" \
        "committed feature work should use the default branch merge-base"
    assert_contains "$(sed -n '1p' <<< "$SCENARIO_COMMANDS")" "<--base><$merge_base>" \
        "dry-run should preview committed work against the merge-base"
    pass "committed feature work uses the known default branch baseline"
}

test_explicit_base_takes_priority() {
    SCENARIO_SLOT_ARGS="--base HEAD~0" run_scenario explicit-base clean

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "an explicit valid base should be accepted"
    assert_contains "$SCENARIO_OUTPUT" "Baseline: HEAD~0" "explicit base should take priority"
    assert_contains "$(sed -n '1p' <<< "$SCENARIO_COMMANDS")" "<--base><HEAD~0>" \
        "preview should preserve the user's explicit base"
    pass "explicit base takes priority over inference"
}

test_mixed_feature_work_preserves_commits_and_worktree_changes() {
    local target="$TEST_ROOT/mixed-feature-target"

    make_committed_feature_target "$target"
    printf '%s\n' 'uncommitted feature' > "$target/worktree.sh"
    SCENARIO_TARGET_OVERRIDE="$target" SCENARIO_SCOPE_COUNT=2 \
        SCENARIO_SCOPE_FILES=$'feature.sh\nworktree.sh' run_scenario mixed-feature clean

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "mixed feature work should select a safe baseline"
    assert_contains "$SCENARIO_OUTPUT" "merge-base of feature and main" \
        "mixed committed and uncommitted work should retain the branch baseline"
    assert_contains "$SCENARIO_OUTPUT" "Review Scope (2): feature.sh worktree.sh" \
        "mixed preview should include both committed and uncommitted changes"
    pass "mixed committed and uncommitted work uses the branch baseline"
}

assert_ambiguous_target_stops_before_cli() {
    local expected="$1"
    [[ $SCENARIO_STATUS -eq 64 ]] || fail "ambiguous Target Repo should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "$expected" "baseline ambiguity should be actionable"
    [[ -z "$SCENARIO_COMMANDS" ]] || fail "baseline ambiguity must stop before review CLI calls"
}

test_detached_head_stops_before_review() {
    local target="$TEST_ROOT/detached-target"
    make_target "$target"
    git -C "$target" checkout -q --detach HEAD
    SCENARIO_TARGET_OVERRIDE="$target" run_scenario detached clean
    assert_ambiguous_target_stops_before_cli "detached HEAD"
    pass "detached HEAD stops before Agent calls"
}

test_shallow_repo_stops_before_review() {
    local source="$TEST_ROOT/shallow-source"
    local target="$TEST_ROOT/shallow-target"
    make_target "$source"
    git clone -q --depth 1 "file://$source" "$target"
    printf '%s\n' 'work' >> "$target/app.sh"
    SCENARIO_TARGET_OVERRIDE="$target" run_scenario shallow clean
    assert_ambiguous_target_stops_before_cli "shallow Target Repo"
    assert_contains "$SCENARIO_OUTPUT" "authorize a separate fetch" \
        "shallow history should disclose that fetch needs separate authorization"
    pass "shallow Target Repo stops without fetching"
}

test_missing_upstream_stops_before_review() {
    local target="$TEST_ROOT/remote-only-target"
    make_target "$target"
    git -C "$target" checkout -qb feature
    git -C "$target" remote add origin "$TEST_ROOT/not-fetched-origin"
    printf '%s\n' 'feature' > "$target/feature.sh"
    git -C "$target" add feature.sh
    git -C "$target" commit -qm feature
    SCENARIO_TARGET_OVERRIDE="$target" run_scenario remote-only clean
    assert_ambiguous_target_stops_before_cli "feature branch has no upstream"
    assert_contains "$SCENARIO_OUTPUT" "authorize a separate fetch" \
        "possibly stale remote refs should require separate fetch authorization"
    pass "missing upstream stops without fetching"
}

test_possibly_stale_upstream_stops_before_review() {
    local target="$TEST_ROOT/stale-upstream-target"
    make_committed_feature_target "$target"
    git -C "$target" remote add origin "$TEST_ROOT/not-fetched-origin"
    git -C "$target" update-ref refs/remotes/origin/feature HEAD
    git -C "$target" update-ref refs/remotes/origin/main main~1
    git -C "$target" branch --set-upstream-to origin/feature feature >/dev/null
    SCENARIO_TARGET_OVERRIDE="$target" run_scenario stale-upstream clean

    assert_ambiguous_target_stops_before_cli "local main differs from origin/main"
    assert_contains "$SCENARIO_OUTPUT" "authorize a separate fetch" \
        "possibly stale upstream should require separate fetch authorization"
    pass "possibly stale upstream stops without fetching"
}

test_missing_remote_default_stops_before_review() {
    local target="$TEST_ROOT/missing-remote-default-target"
    make_committed_feature_target "$target"
    git -C "$target" remote add origin "$TEST_ROOT/not-fetched-origin"
    git -C "$target" update-ref refs/remotes/origin/feature HEAD
    git -C "$target" branch --set-upstream-to origin/feature feature >/dev/null
    SCENARIO_TARGET_OVERRIDE="$target" run_scenario missing-remote-default clean

    assert_ambiguous_target_stops_before_cli "remote default ref is missing: origin/main"
    assert_contains "$SCENARIO_OUTPUT" "authorize a separate fetch" \
        "missing remote default should require separate fetch authorization"
    pass "missing remote-tracking default stops without fetching"
}

test_fresh_remote_default_allows_merge_base() {
    local target="$TEST_ROOT/fresh-remote-target"
    make_committed_feature_target "$target"
    git -C "$target" remote add origin "$TEST_ROOT/not-fetched-origin"
    git -C "$target" update-ref refs/remotes/origin/feature HEAD
    git -C "$target" update-ref refs/remotes/origin/main main
    git -C "$target" branch --set-upstream-to origin/feature feature >/dev/null
    SCENARIO_TARGET_OVERRIDE="$target" SCENARIO_SCOPE_FILES=feature.sh run_scenario fresh-remote clean

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "aligned local and remote defaults should permit baseline inference"
    assert_contains "$SCENARIO_OUTPUT" "merge-base of feature and main" \
        "normal tracked feature branch should use the default merge-base"
    assert_contains "$SCENARIO_OUTPUT" "Remote baseline: local main matches origin/main; no fetch performed" \
        "successful inference should disclose the no-fetch freshness limit"
    pass "aligned remote-tracking default allows merge-base without fetching"
}

test_configured_nonstandard_default_branch_uses_merge_base() {
    local target="$TEST_ROOT/develop-default-target"
    make_target "$target"
    git -C "$target" checkout -qb develop
    git -C "$target" config init.defaultBranch develop
    git -C "$target" add app.sh
    git -C "$target" commit -qm develop-change
    git -C "$target" checkout -qb feature
    printf '%s\n' 'feature' > "$target/feature.sh"
    git -C "$target" add feature.sh
    git -C "$target" commit -qm feature
    SCENARIO_TARGET_OVERRIDE="$target" SCENARIO_SCOPE_FILES=feature.sh run_scenario develop-default clean

    [[ $SCENARIO_STATUS -eq 0 ]] || fail "configured nonstandard default branch should be usable"
    assert_contains "$SCENARIO_OUTPUT" "merge-base of feature and develop" \
        "configured Target Repo default branch should drive baseline selection"
    assert_contains "$SCENARIO_OUTPUT" "Review Scope (1): feature.sh" \
        "configured default branch preview should include committed feature work"
    pass "configured nonstandard default branch uses its merge-base"
}

test_unknown_default_branch_stops() {
    local target="$TEST_ROOT/unknown-default-target"
    make_target "$target"
    git -C "$target" branch topic HEAD
    git -C "$target" checkout -q topic
    git -C "$target" branch -D master >/dev/null
    SCENARIO_TARGET_OVERRIDE="$target" run_scenario unknown-default clean

    assert_ambiguous_target_stops_before_cli "no known default branch"
    pass "unknown default branch stops instead of falling back to HEAD"
}

test_unexpected_whole_repo_scope_stops_before_real_review() {
    local target="$TEST_ROOT/whole-repo-target"
    make_target "$target"
    printf '%s\n' 'unchanged' > "$target/unchanged.sh"
    git -C "$target" add unchanged.sh
    git -C "$target" commit -qm add-unchanged
    printf '%s\n' 'review me' >> "$target/app.sh"
    SCENARIO_TARGET_OVERRIDE="$target" SCENARIO_SCOPE_FILES=unchanged.sh run_scenario whole-repo clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "unexpected whole-repo scope should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "unexpected whole-repo or invalid Review Scope entry: unchanged.sh" \
        "scope entries outside the Git delta should be rejected"
    [[ "$(wc -l <<< "$SCENARIO_COMMANDS" | tr -d ' ')" == "1" ]] ||
        fail "unexpected whole-repo scope must not start a real review"
    pass "unexpected whole-repo dry-run scope stops before real Agent calls"
}

test_oversized_scope_stops_before_real_review() {
    SCENARIO_SCOPE_COUNT=501 run_scenario oversized clean

    [[ $SCENARIO_STATUS -eq 64 ]] || fail "an obviously large Review Scope should stop safely"
    assert_contains "$SCENARIO_OUTPUT" "Review Scope is unexpectedly large" \
        "oversized scope should provide actionable guidance"
    [[ "$(wc -l <<< "$SCENARIO_COMMANDS" | tr -d ' ')" == "1" ]] ||
        fail "oversized scope must not start a real review"
    pass "oversized dry-run scope stops before real Agent calls"
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
test_committed_feature_branch_uses_default_branch_merge_base
test_explicit_base_takes_priority
test_mixed_feature_work_preserves_commits_and_worktree_changes
test_detached_head_stops_before_review
test_shallow_repo_stops_before_review
test_missing_upstream_stops_before_review
test_possibly_stale_upstream_stops_before_review
test_missing_remote_default_stops_before_review
test_fresh_remote_default_allows_merge_base
test_configured_nonstandard_default_branch_uses_merge_base
test_unknown_default_branch_stops
test_unexpected_whole_repo_scope_stops_before_real_review
test_oversized_scope_stops_before_real_review

echo "1..$tests_run"
