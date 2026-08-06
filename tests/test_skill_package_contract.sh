#!/usr/bin/env bash

# High-level contract suite for issue #54: stages the complete
# filesystem-installable Skill package into an isolated skills root outside
# this repository's source tree, and exercises it from there against a
# disposable target repo. Lower-level engine behavior is covered by the
# existing CLI and Skill scenario suites; this suite only asserts what a
# Skill consumer observes after installation: manifest discovery, resolved
# target, explicit review-only execution, the machine-readable result and
# process status, absence of backend calls beyond authentication checks, and
# an unchanged target working tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SOURCE="$REPO_ROOT/.agents/skills/adversarial-review"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"
for utility in bash cat cmp git dirname grep mktemp mv rm sed sort tail awk; do
    ln -s "$(command -v "$utility")" "$TEST_BIN/$utility"
done
ln -s "$(type -P true)" "$TEST_BIN/true"
if command -v jq >/dev/null 2>&1; then
    ln -s "$(command -v jq)" "$TEST_BIN/jq"
elif [[ -x /tmp/adversarial-review-jq ]]; then
    ln -s /tmp/adversarial-review-jq "$TEST_BIN/jq"
else
    echo "not ok - jq is required for the Skill package contract suite" >&2
    exit 1
fi
if command -v timeout >/dev/null 2>&1; then
    ln -s "$(command -v timeout)" "$TEST_BIN/timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    ln -s "$(command -v gtimeout)" "$TEST_BIN/gtimeout"
else
    echo "not ok - a timeout command is required for the Skill package contract suite" >&2
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
    git -C "$target" config user.name "Skill Package Contract Test"
    git -C "$target" config user.email "skill-package-contract@example.com"
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
    printf '%s\n' 'Usage: adversarial_review.sh --base REF --slot-a AGENT --slot-b AGENT --fixer AGENT --target-dir DIR --dry-run --review-only --apply-fixes --result-file FILE'
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
execution_mode=review-only
fixer=""
previous=""
for argument in "$@"; do
    [[ "$previous" == "--result-file" ]] && result_file="$argument"
    [[ "$previous" == "--target-dir" ]] && target_dir="$argument"
    [[ "$previous" == "--base" ]] && base_ref="$argument"
    [[ "$previous" == "--slot-a" ]] && slot_a="$argument"
    [[ "$previous" == "--slot-b" ]] && slot_b="$argument"
    [[ "$previous" == "--fixer" ]] && fixer="$argument"
    [[ "$argument" == "--dry-run" ]] && dry_run=true
    [[ "$argument" == "--apply-fixes" ]] && execution_mode=apply-fixes
    previous="$argument"
done

if [[ "$dry_run" == "true" ]]; then
    cat > "$result_file" <<JSON
{"schema_version":1,"target_repo":{"path":"$target_dir"},"reviewers":{"slot_a":"$slot_a","slot_b":"$slot_b"},"synthesis":{"requested_fixer":"$fixer","executed_by":null},"scope":{"kind":"base","requested_base_ref":"$base_ref","resolved_base_commit":"abc"},"execution":{"mode":"$execution_mode","dry_run":true,"review_executed":false,"include_pre_existing":false},"termination":{"category":"incomplete-review","reason":"max-iterations","exit_code":12},"target_changes":{"modified":false,"files":[]},"paths":{"artifacts_dir":"/tmp/artifacts","final_synthesis_artifact":null}}
JSON
    printf '[INFO] Files in scope (1):\n'
    printf '  app.sh\n'
    printf '[INFO] Execution mode: %s\n' "$execution_mode"
    exit 12
fi

cat > "$result_file" <<JSON
{"schema_version":1,"target_repo":{"identity":"$target_dir","path":"$target_dir","git_root":"$target_dir","remote_url":null,"head_commit":"abc"},"reviewers":{"slot_a":"$slot_a","slot_b":"$slot_b"},"synthesis":{"requested_fixer":"$fixer","executed_by":"$fixer"},"scope":{"kind":"base","requested_base_ref":"$base_ref","resolved_base_commit":"abc"},"execution":{"mode":"$execution_mode","dry_run":false,"review_executed":true,"include_pre_existing":false},"termination":{"category":"clean","reason":"clean","exit_code":0},"iterations":1,"counts":{"findings":{"in_scope":0,"pre_existing":0,"scope_conflicts":0},"fixes":{"in_scope":0,"pre_existing":0},"pre_existing_flagged":0},"target_changes":{"modified":false,"files":[]},"paths":{"state_dir":"/tmp/state","artifacts_dir":"/tmp/artifacts","final_synthesis_artifact":"/tmp/artifacts/iter1_4_synthesis.md"}}
JSON
printf '%s\n' 'CLI terminal narration'
exit 0
EOF
    chmod +x "$fake_cli"
}

make_fake_backend() {
    local backend="$1"
    cat > "$TEST_BIN/$backend" <<EOF
#!/usr/bin/env bash
printf '%s %s\\n' '$backend' "\$*" >> "\${FAKE_BACKEND_LOG:?}"
if [[ "\$*" == 'auth status' || "\$*" == 'login status' ]]; then
    exit 0
fi
exit 99
EOF
    chmod +x "$TEST_BIN/$backend"
}

# Stage the complete filesystem-installable Skill package (manifest, adapter
# script, and supporting resources) into an isolated skills root, mirroring
# a real installation (e.g. into a user's `.claude/skills/` or another
# agent's skills directory) rather than copying just the runner script.
ISOLATED_SKILLS_ROOT="$TEST_ROOT/isolated-skills-root"
mkdir -p "$ISOLATED_SKILLS_ROOT"
cp -R "$SKILL_SOURCE" "$ISOLATED_SKILLS_ROOT/adversarial-review"
STAGED_MANIFEST="$ISOLATED_SKILLS_ROOT/adversarial-review/SKILL.md"
STAGED_RUNNER="$ISOLATED_SKILLS_ROOT/adversarial-review/scripts/run-review.sh"

test_staged_manifest_is_discoverable() {
    [[ -f "$STAGED_MANIFEST" ]] || fail "staged Skill package must include a SKILL.md manifest"
    [[ -x "$STAGED_RUNNER" ]] || fail "staged Skill package must keep run-review.sh executable"

    local frontmatter
    frontmatter="$(awk '/^---$/{c++; next} c==1' "$STAGED_MANIFEST")"
    grep -qxF "name: adversarial-review" <<< "$frontmatter" ||
        fail "staged manifest should expose the stable Skill name 'adversarial-review'"
    grep -qE '^description: .+' <<< "$frontmatter" ||
        fail "staged manifest should expose a non-empty, intent-oriented description"
    pass "staged Skill manifest is discoverable by package convention with a stable name and description"
}

test_isolated_root_review_resolves_target_and_reports_machine_result() {
    local target="$TEST_ROOT/isolated-target"
    local fake_cli="$TEST_ROOT/isolated-cli"
    local output="$TEST_ROOT/isolated.out"
    local command_log="$TEST_ROOT/isolated.commands"
    local backend_log="$TEST_ROOT/isolated.backends"
    local before_head before_status status

    make_target "$target"
    make_fake_cli "$fake_cli"
    make_fake_backend claude
    make_fake_backend codex
    before_head="$(git -C "$target" rev-parse HEAD)"
    before_status="$(git -C "$target" status --porcelain)"

    set +e
    (
        cd "$target"
        PATH="$TEST_BIN" FAKE_COMMAND_LOG="$command_log" FAKE_BACKEND_LOG="$backend_log" \
            "$STAGED_RUNNER" --cli "$fake_cli"
    ) > "$output" 2>&1
    status=$?
    set -e

    [[ $status -eq 0 ]] ||
        fail "Skill package staged outside the source tree should complete a clean review-only run, got exit $status:
$(cat "$output")"
    assert_contains "$(cat "$output")" "Target Repo: $target" \
        "response should report the resolved target directory"
    assert_contains "$(cat "$output")" "Execution mode: review-only" \
        "response should report explicit review-only execution mode"
    assert_contains "$(cat "$output")" "Reviewer slots: claude, codex" \
        "response should report the default heterogeneous reviewer assignment"
    assert_contains "$(cat "$output")" "Review result: clean" \
        "response should report the clean review-only findings-summary category"
    assert_contains "$(cat "$output")" "Termination: clean (status 0)" \
        "response should report the machine-readable termination category and process status"
    [[ "$(wc -l < "$command_log" | tr -d ' ')" == "2" ]] ||
        fail "the staged CLI should receive exactly one dry-run and one real invocation"

    [[ -s "$backend_log" ]] || fail "backend authentication should still be checked before review"
    local backend_calls
    backend_calls="$(sort -u "$backend_log")"
    [[ "$backend_calls" == "$(printf '%s\n%s' 'claude auth status' 'codex login status')" ]] ||
        fail "no Agent backend call beyond authentication checks should occur:
$backend_calls"

    [[ "$(git -C "$target" rev-parse HEAD)" == "$before_head" ]] ||
        fail "the target's HEAD must not change during a review-only run"
    [[ "$(git -C "$target" status --porcelain)" == "$before_status" ]] ||
        fail "the target working tree must remain unchanged during a review-only run"

    pass "Skill package staged in an isolated skills root outside the source tree resolves the target, completes an explicit review-only run against a disposable target repo, reports the machine-readable result and process status, invokes no Agent backend beyond authentication checks, and leaves the target working tree unchanged"
}

test_staged_manifest_is_discoverable
test_isolated_root_review_resolves_target_and_reports_machine_result

echo "1..$tests_run"
