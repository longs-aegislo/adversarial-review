#!/usr/bin/env bash

set -euo pipefail

fail() {
    echo "Adversarial Review stopped: $1" >&2
    exit "${2:-64}"
}

fail_needs_base_or_fetch() {
    fail "$1; provide an explicit base or authorize a separate fetch"
}

write_target_snapshot() {
    local destination="$1"

    {
        git -C "$TARGET_DIR" diff --no-ext-diff --binary HEAD
        git -C "$TARGET_DIR" ls-files --others --exclude-standard -z |
            while IFS= read -r -d '' path; do
                printf 'untracked %s %s\n' "$path" "$(git -C "$TARGET_DIR" hash-object -- "$path")"
            done
    } > "$destination"
}

is_safe_verification_argv() {
    local executable="$1"
    shift

    case "$executable" in
        bash)
            [[ "${1:-}" == "-n" && $# -eq 2 ]] ||
                [[ $# -eq 1 && "$1" != -* ]]
            ;;
        ./*test*|./*check*|./*verify*) [[ $# -eq 0 ]] ;;
        npm|pnpm|yarn)
            [[ $# -eq 1 && "${1:-}" == "test" ]] ||
                [[ $# -eq 2 && "${1:-}" == "run" && "${2:-}" =~ ^(test|check|verify)(:|$) ]]
            ;;
        make) [[ $# -eq 1 && "${1:-}" =~ ^(test|check|verify)$ ]] ;;
        cargo) [[ $# -eq 1 && ("${1:-}" == "test" || "${1:-}" == "check") ]] ;;
        go)
            [[ $# -eq 1 && "${1:-}" == "test" ]] ||
                [[ $# -eq 2 && "${1:-}" == "test" && "${2:-}" == "./..." ]]
            ;;
        pytest) [[ $# -eq 0 ]] ;;
        python|python3) [[ $# -eq 2 && "${1:-}" == "-m" && "${2:-}" == "pytest" ]] ;;
        bundle)
            [[ $# -eq 2 && "${1:-}" == "exec" &&
                ("${2:-}" == "rake" || "${2:-}" == "rspec") ]]
            ;;
        *) return 1 ;;
    esac
}

require_json() {
    local file="$1"
    jq -e . "$file" >/dev/null 2>&1 || fail "CLI did not produce valid machine JSON"
    jq -e '(.schema_version | type == "number" and . == 1 and floor == .)' "$file" >/dev/null 2>&1 ||
        fail "unsupported or invalid result schema: $(jq -r '(.schema_version // "missing") | type + " " + tostring' "$file"); supported schema: integer 1"
}

require_completed_result_contract() {
    local file="$1"

    jq -e '
        (.target_repo.identity | type == "string" and length > 0) and
        (.target_repo.path | type == "string" and length > 0) and
        ((.target_repo.git_root == null) or (.target_repo.git_root | type == "string")) and
        ((.target_repo.remote_url == null) or (.target_repo.remote_url | type == "string")) and
        ((.target_repo.head_commit == null) or (.target_repo.head_commit | type == "string")) and
        (.reviewers.slot_a | type == "string") and
        (.reviewers.slot_b | type == "string") and
        ((.synthesis.requested_fixer == null) or (.synthesis.requested_fixer | type == "string")) and
        ((.synthesis.executed_by == null) or (.synthesis.executed_by | type == "string")) and
        (.scope.kind == "base") and
        (.scope.requested_base_ref | type == "string") and
        (.scope.resolved_base_commit | type == "string" and length > 0) and
        (.execution.mode == "review-only" or .execution.mode == "apply-fixes") and
        (.execution.dry_run == false) and
        (.execution.review_executed | type == "boolean") and
        (.execution.include_pre_existing | type == "boolean") and
        (.termination.reason | type == "string" and length > 0) and
        (.termination.exit_code | type == "number") and
        (.iterations | type == "number" and . >= 0 and floor == .) and
        (.counts.findings.in_scope | type == "number" and . >= 0 and floor == .) and
        (.counts.findings.pre_existing | type == "number" and . >= 0 and floor == .) and
        (.counts.findings.scope_conflicts | type == "number" and . >= 0 and floor == .) and
        (.counts.fixes.in_scope | type == "number" and . >= 0 and floor == .) and
        (.counts.fixes.pre_existing | type == "number" and . >= 0 and floor == .) and
        (.counts.pre_existing_flagged | type == "number" and . >= 0 and floor == .) and
        (.target_changes.modified | type == "boolean") and
        (.target_changes.files | type == "array") and
        (all(.target_changes.files[]; type == "string")) and
        (.paths.state_dir | type == "string" and length > 0) and
        (.paths.artifacts_dir | type == "string" and length > 0) and
        ((.paths.final_synthesis_artifact == null) or
            (.paths.final_synthesis_artifact | type == "string" and length > 0)) and
        ((.target_changes.modified == true) == (.target_changes.files | length > 0)) and
        ((.termination.category == "clean" and .termination.exit_code == 0) or
         (.termination.category == "review-only-findings-remain" and
            .termination.exit_code == 10 and .execution.mode == "review-only") or
         (.termination.category == "apply-fixes-findings-remain" and
            .termination.exit_code == 11 and .execution.mode == "apply-fixes") or
         (.termination.category == "incomplete-review" and .termination.exit_code == 12) or
         (.termination.category == "invalid-invocation" and .termination.exit_code == 64) or
         (.termination.category == "agent-backend-failure" and .termination.exit_code == 70) or
         (.termination.category == "write-boundary-violation" and .termination.exit_code == 77))
    ' "$file" >/dev/null 2>&1 || fail "invalid or contradictory machine result"
}

require_run_contract() {
    local file="$1"
    local expected_dry_run="$2"
    local expected_review_executed="$3"

    [[ "$(jq -r '.target_repo.path' "$file")" == "$TARGET_DIR" ]] ||
        fail "CLI resolved a different Target Repo"
    [[ "$(jq -r '.scope.requested_base_ref' "$file")" == "$BASE_REF" ]] ||
        fail "CLI resolved a different baseline"
    [[ "$(jq -r '.reviewers.slot_a' "$file")" == "$SLOT_A" &&
       "$(jq -r '.reviewers.slot_b' "$file")" == "$SLOT_B" ]] ||
        fail "CLI resolved different reviewer slots"
    [[ "$(jq -r '.execution.mode' "$file")" == "$EXECUTION_MODE" &&
       "$(jq -r '.execution.dry_run' "$file")" == "$expected_dry_run" &&
       "$(jq -r '.execution.include_pre_existing' "$file")" == "false" ]] ||
        fail "CLI did not preserve the execution contract"
    if [[ "$expected_review_executed" == "failure-aware" ]]; then
        review_executed="$(jq -r '.execution.review_executed' "$file")"
        category="$(jq -r '.termination.category' "$file")"
        [[ "$review_executed" == "true" ||
           ("$review_executed" == "false" &&
            ("$category" == "invalid-invocation" || "$category" == "agent-backend-failure")) ]] ||
            fail "CLI did not preserve the execution contract"
    else
        [[ "$(jq -r '.execution.review_executed' "$file")" == "$expected_review_executed" ]] ||
            fail "CLI did not preserve the execution contract"
    fi
    if [[ "$EXECUTION_MODE" == "apply-fixes" ]]; then
        [[ "$(jq -r '.synthesis.requested_fixer' "$file")" == "$FIXER" ]] ||
            fail "CLI resolved a different Fixer"
        if [[ "$expected_review_executed" != "false" ]]; then
            [[ "$(jq -r '.counts.fixes.pre_existing' "$file")" == "0" ]] ||
                fail "CLI modified PRE_EXISTING findings without separate authorization"
        fi
    fi
}

require_cli_contract() {
    local help_output
    help_output="$("$CLI" --help 2>&1)" || fail "Adversarial Review CLI --help check failed"
    for option in --base --slot-a --slot-b --fixer --target-dir --dry-run --review-only --apply-fixes --result-file; do
        [[ "$help_output" == *"$option"* ]] ||
            fail "Adversarial Review CLI does not support required option: $option"
    done
}

require_backend() {
    local backend="$1"
    command -v "$backend" >/dev/null 2>&1 ||
        fail "missing Agent backend executable: $backend"

    case "$backend" in
        claude)
            claude auth status >/dev/null 2>&1 ||
                fail "Claude authentication check failed; authenticate before running a review"
            ;;
        codex)
            codex login status >/dev/null 2>&1 ||
                fail "Codex authentication check failed; authenticate before running a review"
            ;;
        *) fail "unsupported reviewer backend: $backend" ;;
    esac
}

SKILL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLI="${ADVERSARIAL_REVIEW_BIN:-}"
BASE_REF=""
BASE_EXPLICIT=false
BASE_DESCRIPTION=""
REMOTE_BASELINE_NOTE=""
SLOT_A="claude"
SLOT_B="codex"
EXECUTION_MODE="review-only"
FIXER=""
VERIFICATION_EXECUTABLE=""
VERIFICATION_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli) CLI="$2"; shift 2 ;;
        --base) BASE_REF="$2"; BASE_EXPLICIT=true; shift 2 ;;
        --slot-a) SLOT_A="$2"; shift 2 ;;
        --slot-b) SLOT_B="$2"; shift 2 ;;
        --apply-fixes) EXECUTION_MODE="apply-fixes"; shift ;;
        --fixer) FIXER="$2"; shift 2 ;;
        --verification-command) VERIFICATION_EXECUTABLE="$2"; shift 2 ;;
        --verification-arg) VERIFICATION_ARGS+=("$2"); shift 2 ;;
        *) fail "unknown option: $1" ;;
    esac
done

command -v jq >/dev/null 2>&1 || fail "missing dependency: jq"
if [[ -z "$CLI" ]]; then
    CLI="$(command -v adversarial_review.sh 2>/dev/null || true)"
    if [[ -z "$CLI" && -x "$SKILL_SCRIPT_DIR/../../../../adversarial_review.sh" ]]; then
        CLI="$SKILL_SCRIPT_DIR/../../../../adversarial_review.sh"
    fi
fi
if [[ "$CLI" == */* ]]; then
    [[ -x "$CLI" ]] || fail "Adversarial Review CLI is not executable: $CLI"
else
    CLI="$(command -v "$CLI" 2>/dev/null || true)"
    [[ -n "$CLI" ]] || fail "Adversarial Review CLI was not found; set ADVERSARIAL_REVIEW_BIN or pass --cli"
fi
[[ "$SLOT_A" == "claude" || "$SLOT_A" == "codex" ]] ||
    fail "unsupported reviewer backend: $SLOT_A"
[[ "$SLOT_B" == "claude" || "$SLOT_B" == "codex" ]] ||
    fail "unsupported reviewer backend: $SLOT_B"
if [[ "$EXECUTION_MODE" == "apply-fixes" ]]; then
    [[ -n "$FIXER" ]] || fail "--apply-fixes requires an explicit --fixer"
    [[ "$FIXER" == "claude" || "$FIXER" == "codex" ]] || fail "unsupported Fixer: $FIXER"
elif [[ -n "$FIXER" ]]; then
    fail "--fixer is valid only with explicit --apply-fixes authorization"
fi
if [[ -n "$VERIFICATION_EXECUTABLE" ]]; then
    [[ "$EXECUTION_MODE" == "apply-fixes" ]] ||
        fail "--verification-command is valid only with explicit --apply-fixes authorization"
    if ! is_safe_verification_argv "$VERIFICATION_EXECUTABLE" "${VERIFICATION_ARGS[@]}"; then
        fail "verification command expands authorization beyond review-and-fix: $VERIFICATION_EXECUTABLE ${VERIFICATION_ARGS[*]}"
    fi
elif [[ ${#VERIFICATION_ARGS[@]} -gt 0 ]]; then
    fail "--verification-arg requires --verification-command"
fi

TARGET_DIR="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$TARGET_DIR" && -d "$TARGET_DIR" ]] || fail "current workspace is not a Git Target Repo"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

if [[ "$BASE_EXPLICIT" == "false" ]]; then
    [[ "$(git -C "$TARGET_DIR" rev-parse --is-shallow-repository)" == "false" ]] ||
        fail_needs_base_or_fetch "cannot infer a safe baseline for this shallow Target Repo"
    current_branch="$(git -C "$TARGET_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [[ -n "$current_branch" ]] ||
        fail "cannot infer a safe baseline from detached HEAD; provide an explicit base"

    default_branch=""
    configured_default="$(git -C "$TARGET_DIR" config --get init.defaultBranch 2>/dev/null || true)"
    for candidate in "$configured_default" main master; do
        [[ -n "$candidate" ]] || continue
        if git -C "$TARGET_DIR" show-ref --verify --quiet "refs/heads/$candidate"; then
            default_branch="$candidate"
            break
        fi
    done

    if [[ -z "$default_branch" ]]; then
        fail "cannot infer a safe baseline because the Target Repo has no known default branch; provide an explicit base"
    fi

    committed_branch_work=false
    if [[ "$current_branch" != "$default_branch" ]] &&
       [[ "$(git -C "$TARGET_DIR" rev-list --count "$default_branch..HEAD")" -gt 0 ]]; then
        committed_branch_work=true
    fi

    if [[ "$committed_branch_work" == "true" && -n "$(git -C "$TARGET_DIR" remote)" ]]; then
        upstream_ref="$(git -C "$TARGET_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
        if [[ -z "$upstream_ref" ]]; then
            fail_needs_base_or_fetch "cannot infer a safe baseline because the feature branch has no upstream"
        fi

        upstream_remote="$(git -C "$TARGET_DIR" config --get "branch.$current_branch.remote" 2>/dev/null || true)"
        remote_default_ref="refs/remotes/$upstream_remote/$default_branch"
        git -C "$TARGET_DIR" show-ref --verify --quiet "$remote_default_ref" ||
            fail_needs_base_or_fetch "cannot infer a safe baseline because the remote default ref is missing: $upstream_remote/$default_branch"
        if [[ "$(git -C "$TARGET_DIR" rev-parse "$default_branch")" != "$(git -C "$TARGET_DIR" rev-parse "$remote_default_ref")" ]]; then
            fail_needs_base_or_fetch "cannot infer a safe baseline because local $default_branch differs from $upstream_remote/$default_branch"
        fi
        REMOTE_BASELINE_NOTE="local $default_branch matches $upstream_remote/$default_branch; no fetch performed"
    fi

    if [[ "$committed_branch_work" == "true" ]]; then
        BASE_REF="$(git -C "$TARGET_DIR" merge-base HEAD "$default_branch")"
        [[ -n "$BASE_REF" ]] || fail "cannot determine a merge-base for Target Repo branches $current_branch and $default_branch"
        BASE_DESCRIPTION="merge-base of $current_branch and $default_branch"
    else
        BASE_REF="HEAD"
    fi
fi
git -C "$TARGET_DIR" rev-parse --verify --quiet --end-of-options "${BASE_REF}^{commit}" >/dev/null ||
    fail "baseline does not resolve to a commit: $BASE_REF"

TIMEOUT_CMD="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
if [[ -z "$TIMEOUT_CMD" ]]; then
    fail "missing timeout support: install a CLI-compatible timeout command (coreutils on macOS)"
fi
"$TIMEOUT_CMD" 1s true >/dev/null 2>&1 ||
    fail "incompatible timeout support: the timeout command must accept '<duration>s <command>'"
require_cli_contract
require_backend "$SLOT_A"
if [[ "$SLOT_B" != "$SLOT_A" ]]; then
    require_backend "$SLOT_B"
fi

echo "Target Repo: $TARGET_DIR"
echo "Baseline: $BASE_REF${BASE_DESCRIPTION:+ ($BASE_DESCRIPTION)}"
[[ -z "$REMOTE_BASELINE_NOTE" ]] || echo "Remote baseline: $REMOTE_BASELINE_NOTE"
echo "Reviewer slots: $SLOT_A, $SLOT_B"
if [[ "$SLOT_A" == "$SLOT_B" ]]; then
    echo "Review diversity: same-model redundancy provides lower review diversity than heterogeneous reviewers"
fi
echo "Execution mode: $EXECUTION_MODE"
[[ -z "$FIXER" ]] || echo "Fixer: $FIXER"

RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT
DRY_RESULT="$RUN_DIR/dry-run.json"
DRY_OUTPUT="$RUN_DIR/dry-run.out"
REAL_RESULT="$RUN_DIR/review.json"
REAL_OUTPUT="$RUN_DIR/review.out"
BEFORE_REVIEW_SNAPSHOT="$RUN_DIR/before-review.snapshot"

mode_option="--$EXECUTION_MODE"
fixer_args=()
[[ -z "$FIXER" ]] || fixer_args=(--fixer "$FIXER")

set +e
"$CLI" --dry-run "$mode_option" --base "$BASE_REF" \
    --slot-a "$SLOT_A" --slot-b "$SLOT_B" "${fixer_args[@]}" \
    --target-dir "$TARGET_DIR" --result-file "$DRY_RESULT" > "$DRY_OUTPUT" 2>&1
dry_status=$?
set -e

require_json "$DRY_RESULT"
require_run_contract "$DRY_RESULT" true false
DRY_RESOLVED_BASE="$(jq -r '.scope.resolved_base_commit' "$DRY_RESULT")"
[[ $dry_status -eq 12 ]] || fail "dry-run failed: $(jq -r '.termination.reason' "$DRY_RESULT")" "$dry_status"

scope_header="$(sed -n 's/.*Files in scope (\([0-9][0-9]*\)):.*/\1/p' "$DRY_OUTPUT" | tail -1)"
[[ -n "$scope_header" && "$scope_header" -gt 0 ]] || fail "dry-run returned an empty or invalid Review Scope"
[[ "$scope_header" -le 500 ]] ||
    fail "dry-run Review Scope is unexpectedly large ($scope_header files); inspect the baseline or provide a narrower explicit base"
scope_files=()
while IFS= read -r scope_file; do
    scope_files+=("$scope_file")
done < <(awk -v count="$scope_header" '
    /Files in scope \([0-9]+\):/ { reading=1; next }
    reading && captured < count {
        sub(/^[[:space:]]+/, "")
        print
        captured++
    }
' "$DRY_OUTPUT")
[[ ${#scope_files[@]} -eq $scope_header ]] || fail "dry-run Review Scope could not be parsed safely"

expected_scope="$RUN_DIR/expected-scope"
{
    git -C "$TARGET_DIR" diff --name-only "$BASE_REF...HEAD"
    git -C "$TARGET_DIR" diff --name-only
    git -C "$TARGET_DIR" diff --cached --name-only
    git -C "$TARGET_DIR" ls-files --others --exclude-standard
} | sed '/^$/d' | sort -u > "$expected_scope"
for scope_file in "${scope_files[@]}"; do
    grep -Fxq -- "$scope_file" "$expected_scope" ||
        fail "dry-run returned an unexpected whole-repo or invalid Review Scope entry: $scope_file"
done
echo "Review Scope ($scope_header): ${scope_files[*]}"

if [[ "$EXECUTION_MODE" == "review-only" ]]; then
    write_target_snapshot "$BEFORE_REVIEW_SNAPSHOT"
fi

set +e
"$CLI" "$mode_option" --base "$BASE_REF" \
    --slot-a "$SLOT_A" --slot-b "$SLOT_B" "${fixer_args[@]}" \
    --target-dir "$TARGET_DIR" --result-file "$REAL_RESULT" > "$REAL_OUTPUT" 2>&1
review_status=$?
set -e

REVIEW_ONLY_TARGET_CHANGED=false
if [[ "$EXECUTION_MODE" == "review-only" ]]; then
    AFTER_REVIEW_SNAPSHOT="$RUN_DIR/after-review.snapshot"
    write_target_snapshot "$AFTER_REVIEW_SNAPSHOT"
    if cmp -s "$BEFORE_REVIEW_SNAPSHOT" "$AFTER_REVIEW_SNAPSHOT"; then
        echo "Target Repo changes during review: none (confirmed)"
    else
        REVIEW_ONLY_TARGET_CHANGED=true
        echo "Target Repo changes during review: detected (unauthorized)"
    fi
fi

require_json "$REAL_RESULT"
require_completed_result_contract "$REAL_RESULT"
require_run_contract "$REAL_RESULT" false failure-aware
[[ "$(jq -r '.scope.resolved_base_commit' "$REAL_RESULT")" == "$DRY_RESOLVED_BASE" ]] ||
    fail "real review resolved a different baseline commit than dry-run"
[[ "$review_status" -eq "$(jq -r '.termination.exit_code' "$REAL_RESULT")" ]] ||
    fail "invalid or contradictory machine result"
[[ "$REVIEW_ONLY_TARGET_CHANGED" == "false" ||
   "$(jq -r '.termination.category' "$REAL_RESULT")" == "write-boundary-violation" ]] ||
    fail "Target Repo changed during a review-only invocation"

category="$(jq -r '.termination.category' "$REAL_RESULT")"
case "$category" in
    clean)
        echo "Review result: clean"
        ;;
    review-only-findings-remain|apply-fixes-findings-remain)
        echo "Review result: Findings remaining (in scope: $(jq -r '.counts.findings.in_scope' "$REAL_RESULT"), pre-existing: $(jq -r '.counts.findings.pre_existing' "$REAL_RESULT"))"
        ;;
    incomplete-review)
        if [[ "$(jq -r '.termination.reason' "$REAL_RESULT")" == "max-iterations" ]]; then
            echo "Review result: incomplete; inspect the synthesis and artifacts, then rerun with a higher iteration limit if appropriate"
        else
            echo "Review result: incomplete; inspect the synthesis and artifacts before deciding whether to rerun"
        fi
        ;;
    invalid-invocation)
        echo "Review result: invalid invocation; correct the request or prerequisites before retrying"
        ;;
    agent-backend-failure)
        echo "Review result: Agent/backend failure; resolve the backend error before retrying"
        ;;
    write-boundary-violation)
        echo "Review result: write-policy violation; inspect the audit artifacts and Target Repo diff before retrying"
        ;;
esac
echo "Execution: $(jq -r '.execution.mode' "$REAL_RESULT"); Target Repo: $(jq -r '.target_repo.path' "$REAL_RESULT")"
echo "Scope: $(jq -r '.scope.kind' "$REAL_RESULT") $(jq -r '.scope.requested_base_ref' "$REAL_RESULT") (resolved: $(jq -r '.scope.resolved_base_commit' "$REAL_RESULT"))"
echo "Reviewers: slot A $(jq -r '.reviewers.slot_a' "$REAL_RESULT"); slot B $(jq -r '.reviewers.slot_b' "$REAL_RESULT"); Fixer: $(jq -r 'if .synthesis.requested_fixer == null or .synthesis.requested_fixer == "" then "none" else .synthesis.requested_fixer end' "$REAL_RESULT")"
echo "Termination: $category (status $(jq -r '.termination.exit_code' "$REAL_RESULT")); iterations: $(jq -r '.iterations' "$REAL_RESULT")"
echo "Reason: $(jq -r '.termination.reason' "$REAL_RESULT")"
echo "Findings: in scope $(jq -r '.counts.findings.in_scope' "$REAL_RESULT"); pre-existing $(jq -r '.counts.findings.pre_existing' "$REAL_RESULT"); scope conflicts $(jq -r '.counts.findings.scope_conflicts' "$REAL_RESULT")"
echo "Fixes: in scope $(jq -r '.counts.fixes.in_scope' "$REAL_RESULT"); pre-existing $(jq -r '.counts.fixes.pre_existing' "$REAL_RESULT"); pre-existing flagged $(jq -r '.counts.pre_existing_flagged' "$REAL_RESULT")"
case "$category" in
    clean) echo "Remaining findings: none" ;;
    review-only-findings-remain|apply-fixes-findings-remain)
        echo "Remaining findings: present; inspect Synthesis for the unresolved Finding Scope"
        ;;
    *) echo "Remaining findings: unknown because the review did not complete" ;;
esac
mapfile -t modified_files < <(jq -r '.target_changes.files[]' "$REAL_RESULT")
echo "Modified files (${#modified_files[@]}): ${modified_files[*]:-none}"
if [[ "$EXECUTION_MODE" == "apply-fixes" ]]; then
    echo "Applied fixes: in scope $(jq -r '.counts.fixes.in_scope' "$REAL_RESULT"); pre-existing $(jq -r '.counts.fixes.pre_existing' "$REAL_RESULT")"
    echo "Machine-result changed paths (${#modified_files[@]}): ${modified_files[*]:-none}"
    mapfile -t target_diff_files < <({
        git -C "$TARGET_DIR" diff --name-only
        git -C "$TARGET_DIR" diff --cached --name-only
        git -C "$TARGET_DIR" ls-files --others --exclude-standard
    } | sed '/^$/d' | sort -u)
    echo "Target Repo Diff (${#target_diff_files[@]}): ${target_diff_files[*]:-none}"
fi
echo "Synthesis: $(jq -r '.paths.final_synthesis_artifact // "not produced"' "$REAL_RESULT")"
echo "Artifacts: $(jq -r '.paths.artifacts_dir // "not produced"' "$REAL_RESULT")"
echo "State: $(jq -r '.paths.state_dir // "not produced"' "$REAL_RESULT")"
if [[ "$EXECUTION_MODE" == "apply-fixes" ]]; then
    if [[ -z "$VERIFICATION_EXECUTABLE" ]]; then
        echo "Verification: no documented safe command was provided"
    else
        printf 'Verification command:'
        printf ' %q' "$VERIFICATION_EXECUTABLE" "${VERIFICATION_ARGS[@]}"
        printf '\n'
        set +e
        (cd "$TARGET_DIR" && "$VERIFICATION_EXECUTABLE" "${VERIFICATION_ARGS[@]}")
        verification_status=$?
        set -e
        if [[ $verification_status -eq 0 ]]; then
            echo "Verification result: passed"
        else
            echo "Verification result: failed (status $verification_status)"
            [[ $review_status -ne 0 ]] || review_status=$verification_status
        fi
    fi
fi
exit "$review_status"
