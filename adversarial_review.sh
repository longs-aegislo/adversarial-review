#!/usr/bin/env bash
#
# Adversarial Review: Multi-Agent Code Review with Claude + Codex
#
# Implements an adversarial review loop where Claude and GPT Codex
# independently review code, cross-review findings, meta-review feedback,
# and then Claude synthesizes and implements fixes.
#
# Based on patterns from asimov-ralph (https://github.com/frankbria/ralph-claude-code)
#
# Usage:
#   ./adversarial_review.sh [OPTIONS] <slot_a> <slot_b> <target_dir>
#
# Options:
#   -h, --help              Show help message
#   -m, --max-iters N       Maximum iterations (default: 3)
#   -p, --prompt FILE       Additional Phase 1 review criteria file
#   -v, --verbose           Verbose output
#   -t, --timeout MIN       Timeout per agent call in minutes (default: 10)
#   -f, --fixer AGENT       Who implements Phase 4 fixes: claude | codex
#   --slot-a AGENT          Backend for reviewer slot A: claude | codex
#   --slot-b AGENT          Backend for reviewer slot B: claude | codex
#   --target-dir PATH       Project to review
#   -b, --base REF          Review only files differing from this git ref
#   --include-pre-existing  Allow Phase 4 to fix PRE_EXISTING findings
#   --review-only           Declare intent for Phase 4 to run without write
#                           access (mutually exclusive with --apply-fixes)
#   --apply-fixes           Declare intent for Phase 4 to keep today's write
#                           access (mutually exclusive with --review-only)
#   --result-file PATH      Atomically write a machine-readable JSON result
#   --status                Show current status for the required target
#   --reset                 Reset artifacts and tracking for the required target
#   --reset-circuit         Reset circuit breaker for the required target
#   --circuit-status        Show circuit breaker status for the required target
#   --dry-run               Show what would be done without executing
#
# State (tracking.json, circuit breaker, artifacts/) is scoped per target
# directory under state/<slug>/ - see resolve_state_dir() below.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
STATE_ROOT="${AR_STATE_ROOT:-$SCRIPT_DIR/state}"

# Tracking/circuit-breaker/artifacts state is scoped per target directory so
# that running against one project can't leave stale history or an OPEN
# circuit breaker that then blocks (or silently pollutes) a run against a
# different, unrelated project. Find the target dir positional argument
# with a lightweight pre-scan (mirroring main()'s option arities) BEFORE
# sourcing the lib files below, since circuit_breaker.sh/response_analyzer.sh
# compute their state file paths from AR_DIR at source time.
resolve_state_dir() {
    local dir="$1"
    if [[ -z "$dir" ]]; then
        echo "$SCRIPT_DIR"
        return
    fi
    local abs_dir
    abs_dir="$(cd "$dir" 2>/dev/null && pwd || echo "$dir")"
    local slug
    slug="$(basename "$abs_dir" | tr -c 'A-Za-z0-9._-' '_')"
    local hash
    hash="$(echo -n "$abs_dir" | shasum -a 1 | cut -c1-8)"
    echo "$STATE_ROOT/${slug}-${hash}"
}

_prescan_slot_a=""
_prescan_slot_b=""
_prescan_target_dir=""
_prescan_args=("$@")
_prescan_i=0
while [[ $_prescan_i -lt ${#_prescan_args[@]} ]]; do
    _arg="${_prescan_args[$_prescan_i]}"
    case "$_arg" in
        --slot-a)
            _prescan_slot_a="${_prescan_args[$((_prescan_i + 1))]:-}"
            ((_prescan_i+=2)) || true
            ;;
        --slot-b)
            _prescan_slot_b="${_prescan_args[$((_prescan_i + 1))]:-}"
            ((_prescan_i+=2)) || true
            ;;
        --target-dir)
            _prescan_target_dir="${_prescan_args[$((_prescan_i + 1))]:-}"
            ((_prescan_i+=2)) || true
            ;;
        -m|--max-iters|-p|--prompt|-t|--timeout|-f|--fixer|-b|--base|--result-file)
            ((_prescan_i+=2)) || true
            ;;
        -h|--help|-v|--verbose|--status|--reset|--reset-circuit|--circuit-status|--dry-run|--include-pre-existing|--review-only|--apply-fixes)
            ((_prescan_i+=1)) || true
            ;;
        -*)
            ((_prescan_i+=1)) || true
            ;;
        *)
            if [[ -z "$_prescan_slot_a" ]]; then
                _prescan_slot_a="$_arg"
            elif [[ -z "$_prescan_slot_b" ]]; then
                _prescan_slot_b="$_arg"
            elif [[ -z "$_prescan_target_dir" ]]; then
                _prescan_target_dir="$_arg"
            fi
            ((_prescan_i+=1)) || true
            ;;
    esac
done
unset _prescan_args _prescan_i _arg _prescan_slot_a _prescan_slot_b

AR_STATE_DIR="$(resolve_state_dir "$_prescan_target_dir")"
unset _prescan_target_dir
mkdir -p "$AR_STATE_DIR"

# Export AR_DIR for lib scripts
export AR_DIR="$AR_STATE_DIR"
ARTIFACTS_DIR="$AR_DIR/artifacts"
LOGS_DIR="$AR_DIR/logs"
TRACKING_FILE="$AR_DIR/tracking.json"

# Source library components
source "$LIB_DIR/date_utils.sh"
source "$LIB_DIR/circuit_breaker.sh"
source "$LIB_DIR/response_analyzer.sh"

# Defaults
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"
FIXER="${FIXER:-}"
SLOT_A=""
SLOT_B=""
BASE_REF=""
BASE_COMMIT=""
INCLUDE_PRE_EXISTING=0
REVIEW_ONLY=0
APPLY_FIXES=0
EXECUTION_MODE="apply-fixes"
CUSTOM_REVIEW_CRITERIA=""
RESULT_FILE=""
RESULT_FILE_SEEN=0
RESULT_TARGET_DIR=""
RESULT_TARGET_GIT_ROOT=""
RESULT_TARGET_REMOTE=""
RESULT_TARGET_HEAD=""
RESULT_REVIEW_EXECUTED=false
RESULT_SYNTHESIS_EXECUTED_BY=""
RESULT_FINAL_SYNTHESIS_ARTIFACT=""
RESULT_TERMINATION_REASON=""
RESULT_ITERATIONS=0
RESULT_IN_SCOPE_FINDINGS=0
RESULT_PRE_EXISTING_FINDINGS=0
RESULT_IN_SCOPE_FIXED=0
RESULT_PRE_EXISTING_FIXED=0
RESULT_PRE_EXISTING_FLAGGED=0
RESULT_SCOPE_CONFLICTS=0
RESULT_TARGET_SNAPSHOT=""
REVIEW_AVAILABLE_TOOLS="Read,Glob,Grep,Bash"
REVIEW_ALLOWED_TOOLS="Read Glob Grep Bash(git log:*) Bash(git blame:*)"
PHASE_1_CLEAN=0
PHASE_1_CONTINUE=1
PHASE_1_FAILED=2
PHASE_4_COMPLETE=0
PHASE_4_CONTINUE=1
PHASE_4_FAILED=2
PHASE_4_REVIEW_ONLY_FINDINGS=3
PHASE_4_APPLY_FIXES_FINDINGS=4
PHASE_WRITE_BOUNDARY_VIOLATION=65
PHASE_AGENT_RESPONSE_FAILURE=66

# Stable public process exit statuses. These are an external API; internal
# phase and backend return values must be mapped to this contract at the CLI
# boundary rather than leaking through unchanged.
EXIT_CLEAN=0
EXIT_REVIEW_ONLY_FINDINGS=10
EXIT_APPLY_FIXES_FINDINGS=11
EXIT_INCOMPLETE_REVIEW=12
EXIT_INVALID_INVOCATION=64
EXIT_AGENT_BACKEND_FAILURE=70
EXIT_WRITE_BOUNDARY_VIOLATION=77

json_quote() {
    local value="$1"
    local result='"'
    local char code escaped
    local i
    local LC_ALL=C

    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
            '"') result+='\"' ;;
            '\') result+='\\' ;;
            $'\b') result+='\b' ;;
            $'\f') result+='\f' ;;
            $'\n') result+='\n' ;;
            $'\r') result+='\r' ;;
            $'\t') result+='\t' ;;
            *)
                printf -v code '%d' "'$char"
                if [[ $code -lt 32 ]]; then
                    printf -v escaped '\\u%04x' "$code"
                    result+="$escaped"
                else
                    result+="$char"
                fi
                ;;
        esac
    done
    result+='"'
    printf '%s' "$result"
}

json_string_or_null() {
    if [[ -n "$1" ]]; then
        json_quote "$1"
    else
        printf 'null'
    fi
}

result_exit_category() {
    case "$1" in
        "$EXIT_CLEAN") echo "clean" ;;
        "$EXIT_REVIEW_ONLY_FINDINGS") echo "review-only-findings-remain" ;;
        "$EXIT_APPLY_FIXES_FINDINGS") echo "apply-fixes-findings-remain" ;;
        "$EXIT_INCOMPLETE_REVIEW") echo "incomplete-review" ;;
        "$EXIT_INVALID_INVOCATION") echo "invalid-invocation" ;;
        "$EXIT_WRITE_BOUNDARY_VIOLATION") echo "write-boundary-violation" ;;
        *) echo "agent-backend-failure" ;;
    esac
}

infer_result_reason() {
    local exit_code="$1"
    local tracking_status=""

    if [[ -n "$RESULT_TERMINATION_REASON" ]]; then
        printf '%s' "$RESULT_TERMINATION_REASON"
        return
    fi
    if command -v jq >/dev/null 2>&1 && [[ -f "$TRACKING_FILE" ]]; then
        tracking_status="$(jq -r '.status // empty' "$TRACKING_FILE" 2>/dev/null || true)"
    fi
    case "$tracking_status" in
        clean) echo "clean" ;;
        review_complete) echo "clean-synthesis" ;;
        review_complete_findings) echo "review-only-findings-remain" ;;
        fixes_complete_findings) echo "apply-fixes-findings-remain" ;;
        max_iterations) echo "max-iterations" ;;
        circuit_open) echo "circuit-open" ;;
        agent_failed)
            if jq -e '
                [.history[]? |
                    (.result | if type == "string" then
                        (try fromjson catch {}) else . end) |
                    .error? // empty] |
                any(test("missing or malformed"))
            ' "$TRACKING_FILE" >/dev/null 2>&1; then
                echo "malformed-agent-response"
            else
                echo "agent-backend-failure"
            fi
            ;;
        *) result_exit_category "$exit_code" ;;
    esac
}

capture_result_target_identity() {
    local target_dir="$1"
    RESULT_TARGET_DIR="$(cd "$target_dir" && pwd)"
    RESULT_TARGET_GIT_ROOT="$(git -C "$RESULT_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$RESULT_TARGET_GIT_ROOT" ]]; then
        RESULT_TARGET_REMOTE="$(git -C "$RESULT_TARGET_GIT_ROOT" remote get-url origin 2>/dev/null || true)"
        RESULT_TARGET_HEAD="$(git -C "$RESULT_TARGET_GIT_ROOT" rev-parse HEAD 2>/dev/null || true)"
    fi
}

target_file_manifest() {
    local target_dir="$1"
    (
        cd "$target_dir"
        find . -path './.git' -prune -o \( -type f -o -type l \) -print0 2>/dev/null |
            while IFS= read -r -d '' entry; do
                local fingerprint
                if [[ -L "$entry" ]]; then
                    fingerprint="link:$(readlink "$entry")"
                else
                    fingerprint="file:$(shasum -a 256 "$entry" | cut -d' ' -f1)"
                fi
                printf '%s\0%s\0' "$fingerprint" "${entry#./}"
            done
    )
}

collect_result_target_changes() {
    local after_snapshot
    local before_fingerprints=() before_paths=() seen=()
    local after_fingerprint after_path before_fingerprint before_path
    local changed_paths=()
    local i found

    [[ -n "$RESULT_TARGET_SNAPSHOT" && -f "$RESULT_TARGET_SNAPSHOT" &&
       -n "$RESULT_TARGET_DIR" && -d "$RESULT_TARGET_DIR" ]] || {
        printf '[]'
        return
    }

    after_snapshot="$(mktemp)"
    target_file_manifest "$RESULT_TARGET_DIR" > "$after_snapshot"
    while IFS= read -r -d '' before_fingerprint &&
          IFS= read -r -d '' before_path; do
        before_fingerprints+=("$before_fingerprint")
        before_paths+=("$before_path")
        seen+=(false)
    done < "$RESULT_TARGET_SNAPSHOT"

    while IFS= read -r -d '' after_fingerprint &&
          IFS= read -r -d '' after_path; do
        found=false
        for ((i = 0; i < ${#before_paths[@]}; i++)); do
            if [[ "${before_paths[$i]}" == "$after_path" ]]; then
                found=true
                seen[$i]=true
                [[ "${before_fingerprints[$i]}" == "$after_fingerprint" ]] ||
                    changed_paths+=("$after_path")
                break
            fi
        done
        [[ "$found" == "true" ]] || changed_paths+=("$after_path")
    done < "$after_snapshot"
    rm -f "$after_snapshot"

    for ((i = 0; i < ${#before_paths[@]}; i++)); do
        [[ "${seen[$i]}" == "true" ]] || changed_paths+=("${before_paths[$i]}")
    done

    printf '['
    for ((i = 0; i < ${#changed_paths[@]}; i++)); do
        [[ $i -eq 0 ]] || printf ','
        json_quote "${changed_paths[$i]}"
    done
    printf ']'
}

write_result_file() {
    local exit_code="$1"
    local destination_dir destination_base temporary_file
    local category reason modified_files target_modified=false
    local identity scope_kind requested_base resolved_base synthesis_artifact

    [[ -n "$RESULT_FILE" ]] || return 0
    category="$(result_exit_category "$exit_code")"
    reason="$(infer_result_reason "$exit_code")"
    modified_files="$(collect_result_target_changes)"
    [[ "$modified_files" != "[]" ]] && target_modified=true

    destination_dir="$(dirname "$RESULT_FILE")"
    destination_base="$(basename "$RESULT_FILE")"
    [[ ! -d "$RESULT_FILE" ]] || return 1
    mkdir -p "$destination_dir" 2>/dev/null || return 1
    temporary_file="$(mktemp "$destination_dir/.${destination_base}.tmp.XXXXXX" 2>/dev/null)" || return 1
    scope_kind="whole-directory"
    requested_base=""
    resolved_base=""
    if [[ -n "$BASE_REF" ]]; then
        scope_kind="base"
        requested_base="$BASE_REF"
        resolved_base="$BASE_COMMIT"
    fi
    identity="${RESULT_TARGET_REMOTE:-$RESULT_TARGET_DIR}"
    synthesis_artifact="$RESULT_FINAL_SYNTHESIS_ARTIFACT"
    [[ -f "$synthesis_artifact" ]] || synthesis_artifact=""

    {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "target_repo": {"identity": %s, "path": %s, "git_root": %s, "remote_url": %s, "head_commit": %s},\n' \
            "$(json_string_or_null "$identity")" \
            "$(json_string_or_null "$RESULT_TARGET_DIR")" \
            "$(json_string_or_null "$RESULT_TARGET_GIT_ROOT")" \
            "$(json_string_or_null "$RESULT_TARGET_REMOTE")" \
            "$(json_string_or_null "$RESULT_TARGET_HEAD")"
        printf '  "reviewers": {"slot_a": %s, "slot_b": %s},\n' \
            "$(json_string_or_null "$SLOT_A")" "$(json_string_or_null "$SLOT_B")"
        printf '  "synthesis": {"requested_fixer": %s, "executed_by": %s},\n' \
            "$(json_string_or_null "$FIXER")" \
            "$(json_string_or_null "$RESULT_SYNTHESIS_EXECUTED_BY")"
        printf '  "scope": {"kind": %s, "requested_base_ref": %s, "resolved_base_commit": %s},\n' \
            "$(json_quote "$scope_kind")" "$(json_string_or_null "$requested_base")" \
            "$(json_string_or_null "$resolved_base")"
        printf '  "execution": {"mode": %s, "dry_run": %s, "review_executed": %s, "include_pre_existing": %s},\n' \
            "$(json_quote "$EXECUTION_MODE")" \
            "$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
            "$RESULT_REVIEW_EXECUTED" \
            "$([[ "$INCLUDE_PRE_EXISTING" == "1" ]] && echo true || echo false)"
        printf '  "termination": {"category": %s, "reason": %s, "exit_code": %d},\n' \
            "$(json_quote "$category")" "$(json_quote "$reason")" "$exit_code"
        printf '  "iterations": %d,\n' "$RESULT_ITERATIONS"
        printf '  "counts": {"findings": {"in_scope": %d, "pre_existing": %d, "scope_conflicts": %d}, "fixes": {"in_scope": %d, "pre_existing": %d}, "pre_existing_flagged": %d},\n' \
            "$RESULT_IN_SCOPE_FINDINGS" "$RESULT_PRE_EXISTING_FINDINGS" \
            "$RESULT_SCOPE_CONFLICTS" \
            "$RESULT_IN_SCOPE_FIXED" "$RESULT_PRE_EXISTING_FIXED" \
            "$RESULT_PRE_EXISTING_FLAGGED"
        printf '  "target_changes": {"modified": %s, "files": %s},\n' \
            "$target_modified" "$modified_files"
        printf '  "paths": {"state_dir": %s, "artifacts_dir": %s, "final_synthesis_artifact": %s}\n' \
            "$(json_quote "$AR_DIR")" "$(json_quote "$ARTIFACTS_DIR")" \
            "$(json_string_or_null "$synthesis_artifact")"
        printf '}\n'
    } > "$temporary_file" || {
        rm -f "$temporary_file"
        return 1
    }
    if ! mv -f "$temporary_file" "$RESULT_FILE" 2>/dev/null; then
        rm -f "$temporary_file"
        return 1
    fi
}

on_process_exit() {
    local exit_code=$?
    trap - EXIT
    if ! write_result_file "$exit_code"; then
        log_error "Could not atomically write result file: $RESULT_FILE" >&2
    fi
    [[ -z "$RESULT_TARGET_SNAPSHOT" ]] || rm -f "$RESULT_TARGET_SNAPSHOT"
    exit "$exit_code"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_claude()  { echo -e "${MAGENTA}[CLAUDE]${NC} $1"; }
log_codex()   { echo -e "${CYAN}[CODEX]${NC} $1"; }
log_verbose() { [[ "$VERBOSE" == "1" ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" || true; }

log_scope_errors() {
    local status="$1"
    local phase_agent="$2"
    local errors
    errors="$(jq -r '.scope_errors // [] | join(", ")' <<< "$status")"
    if [[ -n "$errors" ]]; then
        log_warning "$phase_agent returned incomplete scope metadata: $errors"
    fi
}

record_agent_failure() {
    local iteration="$1"
    local phase_key="$2"
    local phase_label="$3"
    local agent="$4"
    local detail="$5"
    local artifact="$6"
    local result
    local agent_key

    [[ -n "$RESULT_TERMINATION_REASON" ]] || RESULT_TERMINATION_REASON="agent-backend-failure"

    log_error "$phase_label $agent failed: $detail (artifact: $artifact)" >&2
    update_tracking "status" "agent_failed"
    agent_key="$(printf '%s' "$agent" | tr '[:upper:]' '[:lower:]')"
    result="$(jq -cn \
        --arg error "$detail" \
        --arg artifact "$artifact" \
        '{error: $error, artifact: $artifact}')"
    add_to_history "$iteration" "$phase_key" "$agent_key" "$result"
}

write_invocation_metadata() {
    local output_file="$1"
    local agent="$2"
    local phase="$3"
    local write_authorized="$4"
    local enforcement="$5"
    local available_tools="${6:-}"
    local allowed_tools="${7:-}"
    local metadata_file="${output_file%.md}.invocation.json"

    jq -n \
        --arg agent "$agent" \
        --arg phase "$phase" \
        --arg execution_mode "$EXECUTION_MODE" \
        --argjson write_authorized "$write_authorized" \
        --arg enforcement "$enforcement" \
        --arg available_tools "$available_tools" \
        --arg allowed_tools "$allowed_tools" \
        '{
            agent: $agent,
            phase: $phase,
            execution_mode: $execution_mode,
            write_authorized: $write_authorized,
            enforcement: $enforcement,
            available_tools: $available_tools,
            allowed_tools: $allowed_tools
        }' > "$metadata_file"
}

target_tree_fingerprint() {
    local target_dir="$1"

    (
        cd "$target_dir"
        find . -path './.git' -prune -o \
            \( -type d -o -type f -o -type l \) -print0 2>/dev/null |
            while IFS= read -r -d '' entry; do
                local mode mtime
                if stat -f '%Lp' "$entry" >/dev/null 2>&1; then
                    mode="$(stat -f '%Lp' "$entry")"
                    mtime="$(stat -f '%m:%Sm' "$entry")"
                else
                    mode="$(stat -c '%a' "$entry" 2>/dev/null ||
                        echo unknown)"
                    mtime="$(stat -c '%Y:%y' "$entry" 2>/dev/null ||
                        echo unknown)"
                fi
                if [[ -L "$entry" ]]; then
                    printf 'link\0%s\0%s\0%s\0%s\0' \
                        "$entry" "$mode" "$mtime" "$(readlink "$entry")"
                elif [[ -d "$entry" ]]; then
                    printf 'directory\0%s\0%s\0%s\0' \
                        "$entry" "$mode" "$mtime"
                else
                    printf 'file\0%s\0%s\0%s\0' "$entry" "$mode" "$mtime"
                    shasum -a 256 "$entry"
                fi
            done
    ) | shasum -a 256 | cut -d' ' -f1
}

verify_review_target_unchanged() {
    local iteration="$1"
    local phase_key="$2"
    local phase_label="$3"
    local target_dir="$4"
    local before="$5"
    local after
    local artifact="$ARTIFACTS_DIR/iter${iteration}_${phase_key}_write_violation.json"

    after="$(target_tree_fingerprint "$target_dir")"
    if [[ "$after" == "$before" ]]; then
        return 0
    fi

    jq -n \
        --arg phase "$phase_label" \
        --arg before "$before" \
        --arg after "$after" \
        --arg target "$target_dir" \
        '{
            error: "review phase modified target",
            phase: $phase,
            target: $target,
            before_fingerprint: $before,
            after_fingerprint: $after,
            automatically_reverted: false
        }' > "$artifact"
    record_agent_failure "$iteration" "$phase_key" "$phase_label" "boundary" \
        "target changed during a read-only review phase; changes were not reverted" \
        "$artifact"
    return 1
}

wait_for_review_agents() {
    local iteration="$1"
    local phase_key="$2"
    local phase_label="$3"
    local target_dir="$4"
    local target_before="$5"
    local slot_a_pid="$6"
    local slot_b_pid="$7"
    local slot_a_out="$8"
    local slot_b_out="$9"
    local slot_a_rc=0
    local slot_b_rc=0
    local target_changed=0

    wait "$slot_a_pid" || slot_a_rc=$?
    wait "$slot_b_pid" || slot_b_rc=$?
    verify_review_target_unchanged "$iteration" "$phase_key" "$phase_label" \
        "$target_dir" "$target_before" || target_changed=$?

    if [[ $slot_a_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "$phase_key" "$phase_label" \
            "slot-a ($SLOT_A)" "agent exited with code $slot_a_rc" "$slot_a_out"
    fi
    if [[ $slot_b_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "$phase_key" "$phase_label" \
            "slot-b ($SLOT_B)" "agent exited with code $slot_b_rc" "$slot_b_out"
    fi

    if [[ $target_changed -ne 0 ||
          $slot_a_rc -eq $PHASE_WRITE_BOUNDARY_VIOLATION ||
          $slot_b_rc -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
        return "$PHASE_WRITE_BOUNDARY_VIOLATION"
    fi
    if [[ $slot_a_rc -ne 0 || $slot_b_rc -ne 0 ]]; then
        return "$PHASE_1_FAILED"
    fi
    return 0
}

map_phase_failure_exit() {
    local phase_result="$1"
    if [[ $phase_result -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
        echo "$EXIT_WRITE_BOUNDARY_VIOLATION"
    else
        echo "$EXIT_AGENT_BACKEND_FAILURE"
    fi
}

parse_required_status() {
    local iteration="$1"
    local phase_key="$2"
    local phase_label="$3"
    local agent="$4"
    local artifact="$5"
    local block_name="$6"
    local status

    if ! status="$(parse_status_block "$artifact" "$block_name")"; then
        RESULT_TERMINATION_REASON="malformed-agent-response"
        record_agent_failure "$iteration" "$phase_key" "$phase_label" "$agent" \
            "missing or malformed $block_name block" "$artifact"
        return 1
    fi
    printf '%s\n' "$status"
}

audit_claude_review_transcript() {
    local raw_log="$1"

    jq -e -s '
        [
            .[] |
            select(.type == "assistant") |
            .message.content[]? |
            select(.type == "tool_use") |
            select(
                (
                    .name != "Read" and
                    .name != "Glob" and
                    .name != "Grep" and
                    .name != "Bash"
                ) or
                (
                    .name == "Bash" and
                    (
                        ((.input.command // "") |
                            test("^git (log|blame)([[:space:]]|$)") | not) or
                        ((.input.command // "") |
                            test("[;&|><`\\r\\n]|\\$\\("))
                    )
                )
            )
        ] | length == 0
    ' "$raw_log" >/dev/null
}

audit_codex_review_transcript() {
    local raw_log="$1"

    jq -e -s '
        [
            .[] |
            select(
                (
                    (.type == "item.started" or .type == "item.completed") and
                    .item.type == "file_change"
                ) or
                (
                    (.type == "item.started" or .type == "item.completed") and
                    .item.type == "command_execution" and
                    .item.status == "failed" and
                    ((.item | tostring) |
                        test("(?i)(sandbox|permission denied|read-only file system|operation not permitted)"))
                )
            )
        ] | length == 0
    ' "$raw_log" >/dev/null
}

# Cross-platform timeout command
get_timeout_cmd() {
    if command -v gtimeout &> /dev/null; then
        echo "gtimeout"  # macOS with coreutils
    elif command -v timeout &> /dev/null; then
        echo "timeout"   # Linux
    else
        echo ""
    fi
}

# Check dependencies
check_dependencies() {
    local missing=()

    if [[ "$SLOT_A" == "claude" || "$SLOT_B" == "claude" || "$FIXER" == "claude" ]] &&
       ! command -v claude &> /dev/null; then
        missing+=("claude CLI (npm install -g @anthropic-ai/claude-code)")
    fi

    if [[ "$SLOT_A" == "codex" || "$SLOT_B" == "codex" || "$FIXER" == "codex" ]] &&
       ! command -v codex &> /dev/null; then
        missing+=("codex CLI (npm install -g @openai/codex)")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq (brew install jq)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        RESULT_TERMINATION_REASON="missing-dependency"
        log_error "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit "$EXIT_AGENT_BACKEND_FAILURE"
    fi

    # Check for timeout command (warn but don't fail)
    if [[ -z "$(get_timeout_cmd)" ]]; then
        log_warning "No timeout command found. Install coreutils for timeout support."
    fi
}

# Initialize tracking
init_tracking() {
    mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"

    if [[ ! -f "$TRACKING_FILE" ]]; then
        cat > "$TRACKING_FILE" << EOF
{
    "iteration": 0,
    "status": "pending",
    "target_dir": null,
    "slot_a": null,
    "slot_b": null,
    "base_ref": null,
    "execution_mode": null,
    "include_pre_existing": false,
    "in_scope_findings": 0,
    "pre_existing_findings": 0,
    "scope_conflicts": 0,
    "in_scope_fixed": 0,
    "pre_existing_fixed": 0,
    "pre_existing_flagged": 0,
    "started_at": null,
    "updated_at": null,
    "phases": [],
    "history": []
}
EOF
    fi
}

# Update tracking JSON
update_tracking() {
    local field="$1"
    local value="$2"
    local timestamp
    timestamp=$(get_iso_timestamp)

    local tmp=$(mktemp)
    jq --arg f "$field" --arg v "$value" --arg ts "$timestamp" '
        .[$f] = (if $v | test("^-?[0-9]+$") then ($v | tonumber)
                 elif $v == "true" then true
                 elif $v == "false" then false
                 elif ($v | startswith("[") or startswith("{")) then ($v | fromjson)
                 else $v end) |
        .updated_at = $ts
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

update_result_finding_counts() {
    local first_status="$1"
    local second_status="$2"
    local counts

    counts="$(jq -cn --argjson first "$first_status" --argjson second "$second_status" '
        [($first.issue_scopes // {}), ($second.issue_scopes // {})] |
        map(to_entries[]) |
        group_by(.key) |
        map({
            key: .[0].key,
            values: ([.[].value] | unique),
            scope: (if any(.value == "PRE_EXISTING") then
                "PRE_EXISTING" else "IN_SCOPE" end)
        }) as $findings |
        {
            in_scope: ([$findings[] | select(.scope == "IN_SCOPE")] | length),
            pre_existing: ([$findings[] | select(.scope == "PRE_EXISTING")] | length),
            scope_conflicts: ([$findings[] | select(.values | length > 1)] | length)
        }
    ')"
    RESULT_IN_SCOPE_FINDINGS="$(jq -r '.in_scope' <<< "$counts")"
    RESULT_PRE_EXISTING_FINDINGS="$(jq -r '.pre_existing' <<< "$counts")"
    RESULT_SCOPE_CONFLICTS="$(jq -r '.scope_conflicts' <<< "$counts")"
    update_tracking "in_scope_findings" "$RESULT_IN_SCOPE_FINDINGS"
    update_tracking "pre_existing_findings" "$RESULT_PRE_EXISTING_FINDINGS"
    update_tracking "scope_conflicts" "$RESULT_SCOPE_CONFLICTS"
}

# Add to history
add_to_history() {
    local iteration="$1"
    local phase="$2"
    local agent="$3"
    local result="$4"

    local tmp=$(mktemp)
    jq --arg i "$iteration" --arg p "$phase" --arg a "$agent" --arg r "$result" --arg ts "$(get_iso_timestamp)" '
        .history += [{
            "iteration": ($i | tonumber),
            "phase": $p,
            "agent": $a,
            "result": $r,
            "timestamp": $ts
        }]
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

# List reviewable source files (paths only - agents read file contents
# themselves via their own file tools instead of having everything dumped
# into the prompt, which is what was blowing up prompt size/usage).
is_reviewable_source_file() {
    local file="$1"

    case "$file" in
        *.py|*.php|*.ts|*.tsx|*.js|*.jsx|*.sh) ;;
        *) return 1 ;;
    esac

    case "$file" in
        .*|*/.*|node_modules/*|*/node_modules/*|vendor/*|*/vendor/*|\
        public/*|*/public/*|storage/*|*/storage/*|bootstrap/cache/*|\
        */bootstrap/cache/*|dist/*|*/dist/*|build/*|*/build/*|\
        __pycache__/*|*/__pycache__/*|venv/*|*/venv/*|.venv/*|*/.venv/*)
            return 1
            ;;
    esac
}

collect_file_list() {
    local target_dir="$1"
    local base_ref="${2:-}"

    log_verbose "Listing source files in $target_dir"

    if [[ -z "$base_ref" ]]; then
        (cd "$target_dir" && find . -type f -print0 2>/dev/null |
            while IFS= read -r -d '' file; do
                file="${file#./}"
                if is_reviewable_source_file "$file"; then
                    printf '%s\n' "$file"
                fi
            done | sort)
        return
    fi

    (
        cd "$target_dir"
        local base_commit
        base_commit="$(git rev-parse --verify --end-of-options "${base_ref}^{commit}" 2>/dev/null)" || return 1

        {
            git diff --relative --name-only -z "$base_commit" -- .
            git ls-files --others --exclude-standard -z -- .
        } |
            while IFS= read -r -d '' file; do
                if is_reviewable_source_file "$file"; then
                    printf '%s\n' "$file"
                fi
            done |
            sort -u
    )
}

emit_untracked_file_diff() {
    local file="$1"

    case "$file" in
        .env|.env.*|*.pem|*.key|*_rsa|*_rsa.pub|*.p12|*.pfx|*credential*|*secret*) return ;;
    esac
    [[ -f "$file" ]] || return
    grep -Iq . "$file" 2>/dev/null || return
    echo "=== NEW FILE: $file ==="
    head -c 20000 "$file" 2>/dev/null
    echo ""
}

# Uncommitted diff (tracked changes + new files) against HEAD, so re-review
# passes can focus on what Phase 4 actually touched instead of rescanning
# the whole tree. Since this tool never commits, the diff is cumulative
# across every iteration run so far, not just the latest one - see the
# caller's prompt framing. Empty on iteration 1 or when the target isn't a
# git repo.
collect_recent_diff() {
    local target_dir="$1"
    local iteration="$2"
    local base_ref="${3:-}"

    [[ "$iteration" -le 1 ]] && return 0
    (cd "$target_dir" && git rev-parse --is-inside-work-tree) >/dev/null 2>&1 || return 0

    if [[ -n "$base_ref" ]]; then
        local scoped_files=()
        local scoped_file
        while IFS= read -r scoped_file; do
            [[ -n "$scoped_file" ]] && scoped_files+=("$scoped_file")
        done < <(collect_file_list "$target_dir" "$base_ref")

        if [[ ${#scoped_files[@]} -gt 0 ]]; then
            (cd "$target_dir" && git diff HEAD -- "${scoped_files[@]}" 2>/dev/null)
        fi
    else
        (cd "$target_dir" && git diff HEAD 2>/dev/null)
    fi

    # New (untracked) files: same directory exclusions as source collection,
    # plus a secret-filename denylist and per-file size/binary guards, so
    # this can't leak unignored credentials or dump large/binary blobs into
    # the prompt (git status includes untracked files regardless of size or
    # content, unlike the tracked diff above).
    if [[ -n "$base_ref" ]]; then
        (
            cd "$target_dir"
            git ls-files --others --exclude-standard -z 2>/dev/null |
                while IFS= read -r -d '' file; do
                    is_reviewable_source_file "$file" || continue
                    emit_untracked_file_diff "$file"
                done
        )
    else
        (cd "$target_dir" && git status --porcelain --untracked-files=all 2>/dev/null | while read -r status file; do
            [[ "$status" != "??" ]] && continue
            is_reviewable_source_file "$file" || continue
            emit_untracked_file_diff "$file"
        done)
    fi
}

# Run Claude
run_claude() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"
    local with_permissions="${4:-false}"
    local available_tools="${5:-}"
    local allowed_tools="${6:-}"
    local phase="${7:-unknown}"
    local write_authorized=false
    local enforcement="restricted-tools+dontAsk"
    local structured_review=false

    if [[ "$with_permissions" == "true" ]]; then
        write_authorized=true
        enforcement="bypassPermissions"
    elif [[ -n "$available_tools" ]]; then
        structured_review=true
    fi
    write_invocation_metadata "$output_file" "claude" "$phase" \
        "$write_authorized" "$enforcement" "$available_tools" "$allowed_tools"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_claude "[DRY RUN] Would run Claude (${#prompt} chars) -> $output_file"
        echo "DRY RUN: Claude output" > "$output_file"
        return 0
    fi

    log_claude "Running..."

    local timeout_cmd=$(get_timeout_cmd)
    local timeout_secs=$((TIMEOUT_MINUTES * 60))

    local cmd_args=(--print)
    if [[ "$with_permissions" == "true" ]]; then
        cmd_args+=(--dangerously-skip-permissions)
    elif [[ -n "$available_tools" ]]; then
        cmd_args+=(
            --safe-mode
            --tools "$available_tools"
            --allowedTools "$allowed_tools"
            --permission-mode dontAsk
            --output-format stream-json
            --verbose
        )
    fi

    local raw_log="${output_file%.md}.raw.log"
    local stdout_file="$output_file"
    [[ "$structured_review" == "true" ]] && stdout_file="$raw_log"

    local exit_code=0
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && printf '%s\n' "$prompt" | $timeout_cmd ${timeout_secs}s claude "${cmd_args[@]}") > "$stdout_file" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && printf '%s\n' "$prompt" | claude "${cmd_args[@]}") > "$stdout_file" 2>&1 || exit_code=$?
    fi

    if [[ "$structured_review" == "true" && $exit_code -eq 0 ]]; then
        if ! jq -e . "$raw_log" >/dev/null 2>&1; then
            log_warning "Claude returned a malformed stream-json transcript"
            cp "$raw_log" "$output_file"
            exit_code=$PHASE_AGENT_RESPONSE_FAILURE
        elif ! jq -r -s 'map(select(.type == "result")) | last | .result // empty' \
            "$raw_log" > "$output_file" || [[ ! -s "$output_file" ]]; then
            log_warning "Claude stream-json transcript has no final result"
            cp "$raw_log" "$output_file"
            exit_code=$PHASE_AGENT_RESPONSE_FAILURE
        fi
    fi
    if [[ "$structured_review" == "true" && ! -s "$output_file" &&
          -f "$raw_log" ]]; then
        cp "$raw_log" "$output_file"
    fi

    return $exit_code
}

# Run Codex
run_codex() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"
    local sandbox_mode="${4:-read-only}"
    local phase="${5:-unknown}"
    local write_authorized=false
    local structured_review=false
    [[ "$sandbox_mode" == "workspace-write" ]] && write_authorized=true
    [[ "$sandbox_mode" == "read-only" ]] && structured_review=true
    write_invocation_metadata "$output_file" "codex" "$phase" \
        "$write_authorized" "sandbox:$sandbox_mode"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_codex "[DRY RUN] Would run Codex (${#prompt} chars, sandbox=$sandbox_mode) -> $output_file"
        echo "DRY RUN: Codex output" > "$output_file"
        return 0
    fi

    log_codex "Running..."

    local timeout_cmd=$(get_timeout_cmd)
    local timeout_secs=$((TIMEOUT_MINUTES * 60))

    # codex exec's stdout is the full agent transcript (reasoning summaries,
    # exec/tool calls, file dumps) - not just the final answer. Feeding that
    # raw transcript back into later phases balloons prompt size by orders of
    # magnitude, so capture it separately and use --output-last-message to
    # get only the agent's final reply for $output_file, which is what
    # downstream phases actually cat into their prompts.
    local raw_log="${output_file%.md}.raw.log"
    local json_args=()
    [[ "$structured_review" == "true" ]] && json_args+=(--json)

    local exit_code=0
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && printf '%s\n' "$prompt" | $timeout_cmd ${timeout_secs}s codex exec -s "$sandbox_mode" "${json_args[@]}" --skip-git-repo-check -o "$output_file") > "$raw_log" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && printf '%s\n' "$prompt" | codex exec -s "$sandbox_mode" "${json_args[@]}" --skip-git-repo-check -o "$output_file") > "$raw_log" 2>&1 || exit_code=$?
    fi

    if [[ "$structured_review" == "true" && $exit_code -eq 0 ]]; then
        if ! jq -e . "$raw_log" >/dev/null 2>&1; then
            log_warning "Codex returned a malformed JSONL transcript"
            exit_code=$PHASE_AGENT_RESPONSE_FAILURE
        elif jq -e -s \
            'any(.[]; .type == "error" or .type == "turn.failed")' \
            "$raw_log" >/dev/null; then
            log_warning "Codex reported a failed turn"
            exit_code=$PHASE_AGENT_RESPONSE_FAILURE
        fi
    fi

    # If codex failed before writing a final message (crash, timeout), fall
    # back to the raw transcript so callers still have something to parse.
    if [[ ! -s "$output_file" ]]; then
        cp "$raw_log" "$output_file"
    fi

    return $exit_code
}

run_backend() {
    local backend_name="$1"
    local prompt="$2"
    local output_file="$3"
    local working_dir="${4:-$PWD}"
    local mode="${5:-read-only}"
    local phase="${6:-unknown}"
    local exit_code=0
    local raw_log="${output_file%.md}.raw.log"
    local backend_label

    case "$backend_name:$mode" in
        claude:read-only)
            run_claude "$prompt" "$output_file" "$working_dir" "false" \
                "$REVIEW_AVAILABLE_TOOLS" "$REVIEW_ALLOWED_TOOLS" "$phase" ||
                exit_code=$?
            if [[ $exit_code -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
                exit_code=$PHASE_AGENT_RESPONSE_FAILURE
            fi
            if [[ "$DRY_RUN" != "1" && -f "$raw_log" ]] &&
               jq -e . "$raw_log" >/dev/null 2>&1 &&
               ! audit_claude_review_transcript "$raw_log"; then
                log_warning "Claude attempted a tool outside the read-only review contract"
                exit_code=$PHASE_WRITE_BOUNDARY_VIOLATION
            fi
            ;;
        claude:workspace-write)
            run_claude "$prompt" "$output_file" "$working_dir" "true" "" "" \
                "$phase" ||
                exit_code=$?
            if [[ $exit_code -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
                exit_code=$PHASE_AGENT_RESPONSE_FAILURE
            fi
            ;;
        codex:read-only|codex:workspace-write)
            run_codex "$prompt" "$output_file" "$working_dir" "$mode" "$phase" ||
                exit_code=$?
            if [[ $exit_code -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
                exit_code=$PHASE_AGENT_RESPONSE_FAILURE
            fi
            if [[ "$mode" == "read-only" && "$DRY_RUN" != "1" &&
                  -f "$raw_log" ]] &&
               jq -e . "$raw_log" >/dev/null 2>&1 &&
               ! audit_codex_review_transcript "$raw_log"; then
                log_warning "Codex attempted a write outside the read-only review contract"
                exit_code=$PHASE_WRITE_BOUNDARY_VIOLATION
            fi
            ;;
        *)
            log_warning "Unsupported backend/mode combination: $backend_name:$mode"
            return "$EXIT_INVALID_INVOCATION"
            ;;
    esac

    [[ "$DRY_RUN" == "1" ]] && return "$exit_code"

    if [[ $exit_code -eq 0 ]]; then
        if [[ "$backend_name" == "claude" ]]; then
            log_claude "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
        else
            log_codex "Complete ($(wc -l < "$output_file" | tr -d ' ') lines, raw transcript $(wc -l < "$raw_log" | tr -d ' ') lines)"
        fi
    else
        [[ "$backend_name" == "claude" ]] &&
            backend_label="Claude" || backend_label="Codex"
        if [[ $exit_code -eq 124 ]]; then
            log_warning "$backend_label timed out after ${TIMEOUT_MINUTES}m"
        else
            log_warning "$backend_label exited with code $exit_code"
        fi
    fi

    return "$exit_code"
}

# Both agents number their issues starting from 1 in every phase; without
# telling each one which agent it is, their IDs collide (both produce
# ISSUE-1, ISSUE-2, ...) once merged in cross-review/meta-review/synthesis.
# Prepended to each agent's own prompt variant so it prefixes its IDs with
# a globally-unique agent tag instead.
agent_id_header() {
    local agent_tag="$1"
    local slot_name="$2"
    echo "# REVIEWER SLOT: ${slot_name}

# YOUR AGENT ID: ${agent_tag}

Prefix every issue ID you produce in this response with this tag, e.g.
\`${agent_tag}-1\`, \`${agent_tag}-2\`, ... The other agent is reviewing the
same code independently and will use a different tag, so these IDs must
stay globally unique once both of your findings are merged together in
later phases."
}

reviewer_tag() {
    local slot_name="$1"
    local backend="$2"
    local tag
    tag="$(printf '%s' "$backend" | tr '[:lower:]' '[:upper:]')"
    if [[ "$SLOT_A" == "$SLOT_B" ]]; then
        [[ "$slot_name" == "slot-a" ]] && echo "${tag}-A" || echo "${tag}-B"
    else
        echo "$tag"
    fi
}

validate_review_only_synthesis() {
    local output_file="$1"
    local status="$2"
    local required_issue_ids="$3"
    local issue_id summary

    grep -qE '^#{1,6}[[:space:]]+Unresolved in-scope findings[[:space:]]*$' \
        "$output_file" || return 1
    grep -qE '^#{1,6}[[:space:]]+Pre-existing issues noticed, not fixed[[:space:]]*$' \
        "$output_file" || return 1
    ! grep -qE '^#{1,6}[[:space:]]+Fix([[:space:]#:].*)?$|^\*\*Change\*\*:' \
        "$output_file" || return 1
    while IFS= read -r issue_id; do
        [[ -z "$issue_id" ]] || grep -Fq "$issue_id" "$output_file" || return 1
    done <<< "$required_issue_ids"
    summary="$(jq -r '.summary // ""' <<< "$status")"
    ! grep -Eqi \
        '^(fixed|implemented|applied)|^((all|the|these|those|accepted|reported|[1-9][0-9]*)[[:space:]]+)?(findings?|issues?)[[:space:]]+(was|were|is|are|has been|have been)[[:space:]]+(fixed|implemented|applied)' \
        <<< "$summary" || return 1
    jq -e '
        [
            (.high_confidence_fixes // 0),
            (.medium_confidence_fixes // 0),
            (.files_modified // 0),
            (.in_scope_fixed // 0),
            (.pre_existing_fixed // 0)
        ] | all(. == 0)
    ' <<< "$status" >/dev/null
}

review_artifact() {
    local iteration="$1"
    local phase="$2"
    local slot_name="$3"
    local backend other_backend artifact_dir="$ARTIFACTS_DIR"
    if [[ "$slot_name" == "slot-a" ]]; then
        backend="$SLOT_A"
        other_backend="$SLOT_B"
    else
        backend="$SLOT_B"
        other_backend="$SLOT_A"
    fi

    if [[ "$SLOT_A" == "$SLOT_B" ]]; then
        artifact_dir="$ARTIFACTS_DIR/$slot_name"
        mkdir -p "$artifact_dir"
    fi

    case "$phase" in
        1) echo "$artifact_dir/iter${iteration}_1_${backend}_review.md" ;;
        2) echo "$artifact_dir/iter${iteration}_2_${backend}_on_${other_backend}.md" ;;
        3) echo "$artifact_dir/iter${iteration}_3_${backend}_meta.md" ;;
    esac
}

render_reviewer_prompt() {
    local template="$1"
    local other_backend="$2"
    local self_tag="$3"
    local other_tag="$4"
    template="${template//\{\{OTHER_REVIEWER_NAME\}\}/$other_backend}"
    template="${template//\{\{SELF_REVIEWER_TAG\}\}/$self_tag}"
    printf '%s' "${template//\{\{OTHER_REVIEWER_TAG\}\}/$other_tag}"
}

# ============================================================================
# PHASE 1: Independent Reviews
# ============================================================================
run_phase_1() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 1: Independent Reviews ==="

    local file_list
    file_list="$(collect_file_list "$target_dir" "$BASE_COMMIT")"
    local recent_diff
    recent_diff="$(collect_recent_diff "$target_dir" "$iteration" "$BASE_COMMIT")"
    local prompt_template=$(cat "$PROMPTS_DIR/initial_review.md")
    local scope_classification_context
    if [[ -n "$BASE_REF" ]]; then
        scope_classification_context="This run is scoped to changes since \`$BASE_REF\` (resolved commit
\`$BASE_COMMIT\`). Findings in the listed changed-file set default to
\`IN_SCOPE\`; anything noticed outside that set defaults to \`PRE_EXISTING\`.
Use line history when a changed file contains both old and new code."
    else
        scope_classification_context="This is a whole-directory scan with no \`--base\` boundary. Classify each
finding against repository history: use \`git blame\` on the affected lines
and/or \`git log -1 -- <file>\`. A finding that predates the work being
reviewed is \`PRE_EXISTING\`, even though its file appears in this list."
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        local file_count
        file_count="$(printf '%s\n' "$file_list" | awk 'NF { count++ } END { print count + 0 }')"
        if [[ -n "$BASE_REF" ]]; then
            log_info "Scope: base-scoped ($BASE_REF)"
        else
            log_info "Scope: whole-directory"
        fi
        log_info "Files in scope ($file_count):"
        printf '%s\n' "$file_list"
    fi

    local diff_section=""
    if [[ -n "$recent_diff" ]]; then
        diff_section="
---
# UNCOMMITTED CHANGES (diff against HEAD)

This tool does not commit between iterations, so this is every uncommitted
change accumulated across ALL review iterations so far in this run, not
just the most recent one - treat it as the full working-tree diff, not an
incremental delta.

$recent_diff
"
    fi

    local custom_criteria_section=""
    if [[ -n "$CUSTOM_REVIEW_CRITERIA" ]]; then
        custom_criteria_section="---
# ADDITIONAL REVIEW CRITERIA

The following caller-supplied criteria apply only to this run. They add to,
and do not replace, the mandatory review and output protocol below.

---BEGIN_ADDITIONAL_REVIEW_CRITERIA---
$CUSTOM_REVIEW_CRITERIA
---END_ADDITIONAL_REVIEW_CRITERIA---
"
    fi

    local common_prompt="$custom_criteria_section
$prompt_template

---
# WORKING DIRECTORY

$target_dir

# FILES IN SCOPE

You have NOT been given file contents here - only paths. Use your own
file-reading tools to open whichever of these files you need directly in
the working directory above before reporting any finding. Do not guess at
file contents.

$file_list

# SCOPE CLASSIFICATION CONTEXT

$scope_classification_context
$diff_section"

    local slot_a_tag slot_b_tag
    slot_a_tag="$(reviewer_tag "slot-a" "$SLOT_A")"
    slot_b_tag="$(reviewer_tag "slot-b" "$SLOT_B")"
    local slot_a_common slot_b_common
    slot_a_common="${common_prompt//\{\{SELF_REVIEWER_TAG\}\}/$slot_a_tag}"
    slot_b_common="${common_prompt//\{\{SELF_REVIEWER_TAG\}\}/$slot_b_tag}"
    local slot_a_prompt="$(agent_id_header "$slot_a_tag" "slot-a")

$slot_a_common"
    local slot_b_prompt="$(agent_id_header "$slot_b_tag" "slot-b")

$slot_b_common"

    local slot_a_out slot_b_out
    slot_a_out="$(review_artifact "$iteration" 1 "slot-a")"
    slot_b_out="$(review_artifact "$iteration" 1 "slot-b")"
    local target_before
    target_before="$(target_tree_fingerprint "$target_dir")"

    # Run in parallel
    run_backend "$SLOT_A" "$slot_a_prompt" "$slot_a_out" "$target_dir" \
        "read-only" "phase_1" &
    local slot_a_pid=$!

    run_backend "$SLOT_B" "$slot_b_prompt" "$slot_b_out" "$target_dir" \
        "read-only" "phase_1" &
    local slot_b_pid=$!

    wait_for_review_agents "$iteration" "phase_1" "Phase 1" \
        "$target_dir" "$target_before" "$slot_a_pid" "$slot_b_pid" \
        "$slot_a_out" "$slot_b_out" || return $?

    [[ "$DRY_RUN" == "1" ]] && return "$PHASE_1_CONTINUE"

    # Parse results
    local slot_a_status
    local slot_b_status
    if ! slot_a_status="$(parse_required_status "$iteration" "phase_1" \
        "Phase 1" "slot-a ($SLOT_A)" "$slot_a_out" "REVIEW_STATUS")"; then
        return "$PHASE_1_FAILED"
    fi
    if ! slot_b_status="$(parse_required_status "$iteration" "phase_1" \
        "Phase 1" "slot-b ($SLOT_B)" "$slot_b_out" "REVIEW_STATUS")"; then
        return "$PHASE_1_FAILED"
    fi
    log_scope_errors "$slot_a_status" "Phase 1 slot-a ($SLOT_A)"
    log_scope_errors "$slot_b_status" "Phase 1 slot-b ($SLOT_B)"

    local slot_a_exit=$(echo "$slot_a_status" | jq -r '.exit_signal // false')
    local slot_b_exit=$(echo "$slot_b_status" | jq -r '.exit_signal // false')

    add_to_history "$iteration" "phase_1" "$SLOT_A" "$slot_a_status"
    add_to_history "$iteration" "phase_1" "$SLOT_B" "$slot_b_status"
    update_result_finding_counts "$slot_a_status" "$slot_b_status"

    # Check for dual NO_ISSUES
    if [[ "$slot_a_exit" == "true" ]] && [[ "$slot_b_exit" == "true" ]]; then
        log_success "Both agents report NO_ISSUES"
        return "$PHASE_1_CLEAN"
    fi

    local slot_a_issues=$(echo "$slot_a_status" | jq -r '.issues_found // 0')
    local slot_b_issues=$(echo "$slot_b_status" | jq -r '.issues_found // 0')
    local slot_a_summary=$(echo "$slot_a_status" | jq -r '.summary // "(no summary)"')
    local slot_b_summary=$(echo "$slot_b_status" | jq -r '.summary // "(no summary)"')

    log_info "Slot A ($SLOT_A) found: $slot_a_issues issues - $slot_a_summary"
    log_info "Slot B ($SLOT_B) found: $slot_b_issues issues - $slot_b_summary"

    return "$PHASE_1_CONTINUE"
}

# ============================================================================
# PHASE 2: Cross-Review
# ============================================================================
run_phase_2() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 2: Cross-Review ==="

    local slot_a_review slot_b_review
    slot_a_review="$(review_artifact "$iteration" 1 "slot-a")"
    slot_b_review="$(review_artifact "$iteration" 1 "slot-b")"

    local cross_prompt=$(cat "$PROMPTS_DIR/cross_review.md")
    local slot_a_cross_prompt slot_b_cross_prompt
    local slot_a_tag slot_b_tag
    slot_a_tag="$(reviewer_tag "slot-a" "$SLOT_A")"
    slot_b_tag="$(reviewer_tag "slot-b" "$SLOT_B")"
    slot_a_cross_prompt="$(render_reviewer_prompt "$cross_prompt" "$SLOT_B" "$slot_a_tag" "$slot_b_tag")"
    slot_b_cross_prompt="$(render_reviewer_prompt "$cross_prompt" "$SLOT_A" "$slot_b_tag" "$slot_a_tag")"

    local slot_a_prompt="$(agent_id_header "$slot_a_tag" "slot-a")

$slot_a_cross_prompt

---
# THE OTHER AGENT'S REVIEW TO ANALYZE

$(cat "$slot_b_review")
"

    local slot_b_prompt="$(agent_id_header "$slot_b_tag" "slot-b")

$slot_b_cross_prompt

---
# THE OTHER AGENT'S REVIEW TO ANALYZE

$(cat "$slot_a_review")
"

    local slot_a_out slot_b_out
    slot_a_out="$(review_artifact "$iteration" 2 "slot-a")"
    slot_b_out="$(review_artifact "$iteration" 2 "slot-b")"
    local target_before
    target_before="$(target_tree_fingerprint "$target_dir")"

    run_backend "$SLOT_A" "$slot_a_prompt" "$slot_a_out" "$target_dir" \
        "read-only" "phase_2" &
    local slot_a_pid=$!

    run_backend "$SLOT_B" "$slot_b_prompt" "$slot_b_out" "$target_dir" \
        "read-only" "phase_2" &
    local slot_b_pid=$!

    wait_for_review_agents "$iteration" "phase_2" "Phase 2" \
        "$target_dir" "$target_before" "$slot_a_pid" "$slot_b_pid" \
        "$slot_a_out" "$slot_b_out" || return $?

    [[ "$DRY_RUN" == "1" ]] && return 0

    local slot_a_status
    local slot_b_status
    if ! slot_a_status="$(parse_required_status "$iteration" "phase_2" \
        "Phase 2" "slot-a ($SLOT_A)" "$slot_a_out" "CROSS_REVIEW_STATUS")"; then
        return 1
    fi
    if ! slot_b_status="$(parse_required_status "$iteration" "phase_2" \
        "Phase 2" "slot-b ($SLOT_B)" "$slot_b_out" "CROSS_REVIEW_STATUS")"; then
        return 1
    fi
    log_scope_errors "$slot_a_status" "Phase 2 slot-a ($SLOT_A)"
    log_scope_errors "$slot_b_status" "Phase 2 slot-b ($SLOT_B)"

    add_to_history "$iteration" "phase_2" "$SLOT_A" "$slot_a_status"
    add_to_history "$iteration" "phase_2" "$SLOT_B" "$slot_b_status"

    local slot_a_summary=$(echo "$slot_a_status" | jq -r '.summary // "(no summary)"')
    local slot_b_summary=$(echo "$slot_b_status" | jq -r '.summary // "(no summary)"')

    log_info "Slot A ($SLOT_A) on slot B ($SLOT_B): $slot_a_summary"
    log_info "Slot B ($SLOT_B) on slot A ($SLOT_A): $slot_b_summary"

    log_success "Cross-review complete"
}

# ============================================================================
# PHASE 3: Meta-Review
# ============================================================================
run_phase_3() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 3: Meta-Review ==="

    local slot_a_on_b slot_b_on_a slot_a_review slot_b_review
    slot_a_on_b="$(review_artifact "$iteration" 2 "slot-a")"
    slot_b_on_a="$(review_artifact "$iteration" 2 "slot-b")"
    slot_a_review="$(review_artifact "$iteration" 1 "slot-a")"
    slot_b_review="$(review_artifact "$iteration" 1 "slot-b")"

    local meta_prompt=$(cat "$PROMPTS_DIR/meta_review.md")
    local slot_a_meta_prompt slot_b_meta_prompt
    local slot_a_tag slot_b_tag
    slot_a_tag="$(reviewer_tag "slot-a" "$SLOT_A")"
    slot_b_tag="$(reviewer_tag "slot-b" "$SLOT_B")"
    slot_a_meta_prompt="$(render_reviewer_prompt "$meta_prompt" "$SLOT_B" "$slot_a_tag" "$slot_b_tag")"
    slot_b_meta_prompt="$(render_reviewer_prompt "$meta_prompt" "$SLOT_A" "$slot_b_tag" "$slot_a_tag")"

    # Each phase runs as a fresh, stateless CLI invocation with no memory of
    # earlier phases, so the meta-review prompt has to re-supply everything
    # needed to reach a full consensus: both agents' original Phase 1
    # findings AND this agent's own Phase 2 verdicts on the other agent's
    # findings - not just the feedback the other agent gave back. Without
    # this, an agent has no way to rule on the other side's issues at all in
    # Phase 3, and they silently vanish from the consensus list.

    local slot_a_prompt="$(agent_id_header "$slot_a_tag" "slot-a")

$slot_a_meta_prompt

---
# YOUR ORIGINAL REVIEW (Phase 1)

$(cat "$slot_a_review")

---
# THE OTHER AGENT'S ORIGINAL REVIEW (Phase 1)

$(cat "$slot_b_review")

---
# YOUR OWN CROSS-REVIEW OF THEIR FINDINGS (Phase 2)

$(cat "$slot_a_on_b")

---
# FEEDBACK ON YOUR ORIGINAL REVIEW (Phase 2)

$(cat "$slot_b_on_a")
"

    local slot_b_prompt="$(agent_id_header "$slot_b_tag" "slot-b")

$slot_b_meta_prompt

---
# YOUR ORIGINAL REVIEW (Phase 1)

$(cat "$slot_b_review")

---
# THE OTHER AGENT'S ORIGINAL REVIEW (Phase 1)

$(cat "$slot_a_review")

---
# YOUR OWN CROSS-REVIEW OF THEIR FINDINGS (Phase 2)

$(cat "$slot_b_on_a")

---
# FEEDBACK ON YOUR ORIGINAL REVIEW (Phase 2)

$(cat "$slot_a_on_b")
"

    local slot_a_out slot_b_out
    slot_a_out="$(review_artifact "$iteration" 3 "slot-a")"
    slot_b_out="$(review_artifact "$iteration" 3 "slot-b")"
    local target_before
    target_before="$(target_tree_fingerprint "$target_dir")"

    run_backend "$SLOT_A" "$slot_a_prompt" "$slot_a_out" "$target_dir" \
        "read-only" "phase_3" &
    local slot_a_pid=$!

    run_backend "$SLOT_B" "$slot_b_prompt" "$slot_b_out" "$target_dir" \
        "read-only" "phase_3" &
    local slot_b_pid=$!

    wait_for_review_agents "$iteration" "phase_3" "Phase 3" \
        "$target_dir" "$target_before" "$slot_a_pid" "$slot_b_pid" \
        "$slot_a_out" "$slot_b_out" || return $?

    [[ "$DRY_RUN" == "1" ]] && return 0

    local slot_a_status
    local slot_b_status
    if ! slot_a_status="$(parse_required_status "$iteration" "phase_3" \
        "Phase 3" "slot-a ($SLOT_A)" "$slot_a_out" "META_REVIEW_STATUS")"; then
        return 1
    fi
    if ! slot_b_status="$(parse_required_status "$iteration" "phase_3" \
        "Phase 3" "slot-b ($SLOT_B)" "$slot_b_out" "META_REVIEW_STATUS")"; then
        return 1
    fi
    log_scope_errors "$slot_a_status" "Phase 3 slot-a ($SLOT_A)"
    log_scope_errors "$slot_b_status" "Phase 3 slot-b ($SLOT_B)"

    add_to_history "$iteration" "phase_3" "$SLOT_A" "$slot_a_status"
    add_to_history "$iteration" "phase_3" "$SLOT_B" "$slot_b_status"
    update_result_finding_counts "$slot_a_status" "$slot_b_status"

    local slot_a_summary=$(echo "$slot_a_status" | jq -r '.summary // "(no summary)"')
    local slot_b_summary=$(echo "$slot_b_status" | jq -r '.summary // "(no summary)"')

    log_info "Slot A ($SLOT_A) meta-review: $slot_a_summary"
    log_info "Slot B ($SLOT_B) meta-review: $slot_b_summary"

    log_success "Meta-review complete"
}

# ============================================================================
# PHASE 4: Synthesis & Implementation
# ============================================================================
run_phase_4() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 4: Synthesis & Implementation ==="

    local synthesis_prompt
    synthesis_prompt="$(cat "$PROMPTS_DIR/synthesis.md")"
    synthesis_prompt="${synthesis_prompt//\{\{SLOT_A_REVIEWER_NAME\}\}/$SLOT_A}"
    synthesis_prompt="${synthesis_prompt//\{\{SLOT_B_REVIEWER_NAME\}\}/$SLOT_B}"
    local slot_a_tag slot_b_tag
    slot_a_tag="$(reviewer_tag "slot-a" "$SLOT_A")"
    slot_b_tag="$(reviewer_tag "slot-b" "$SLOT_B")"
    synthesis_prompt="${synthesis_prompt//\{\{SLOT_A_REVIEWER_TAG\}\}/$slot_a_tag}"
    synthesis_prompt="${synthesis_prompt//\{\{SLOT_B_REVIEWER_TAG\}\}/$slot_b_tag}"
    local execution_policy scope_policy
    if [[ "$EXECUTION_MODE" == "review-only" ]]; then
        execution_policy="# PHASE 4 EXECUTION MODE: REVIEW ONLY

This Phase 4 invocation is read-only. Synthesize the full Phase 1-3 review
chain, but do not edit, create, delete, rename, chmod, or otherwise modify any
file in the target repository. Do not run formatters, tests, or commands that
can change repository state.

Report every accepted finding that remains unresolved under exactly these two
headings, keeping the resolved \`ISSUE_SCOPES\` classifications intact:

- \`Unresolved in-scope findings\`
- \`Pre-existing issues noticed, not fixed\`

For each finding give its ID, file, line, severity, and suggested fix. Use
explicit \"none\" text when a category is empty. Never state or imply that a
finding was fixed. Set all fixed and modified counts to 0. Set \`EXIT_SIGNAL\`
to true once every finding has been classified and reported; in review-only
mode that means synthesis is complete, not that the findings were fixed."
    else
        execution_policy="# PHASE 4 EXECUTION MODE: APPLY FIXES

Synthesize the full Phase 1-3 review chain and implement fixes using the
existing confidence and finding-scope rules below."
    fi

    if [[ "$EXECUTION_MODE" == "review-only" ]]; then
        scope_policy="# PHASE 4 SCOPE POLICY

Preserve every resolved \`IN_SCOPE\` / \`PRE_EXISTING\` classification from
the Phase 1-3 issue ledger. Report unresolved findings in separate scope
categories. No finding may be implemented in review-only mode, including when
the caller also supplied \`--include-pre-existing\`."
        [[ "$DRY_RUN" == "1" ]] && log_info \
            "Phase 4 scope policy: report unresolved IN_SCOPE and PRE_EXISTING findings without applying changes"
    elif [[ "$INCLUDE_PRE_EXISTING" == "1" ]]; then
        scope_policy="# PHASE 4 SCOPE POLICY

The caller explicitly enabled \`--include-pre-existing\`. Implement valid
\`IN_SCOPE\` and \`PRE_EXISTING\` findings. Keep the two categories separate
in the synthesis report and status counts."
        [[ "$DRY_RUN" == "1" ]] && log_info \
            "Phase 4 scope policy: fix IN_SCOPE and PRE_EXISTING findings (--include-pre-existing enabled)"
    else
        scope_policy="# PHASE 4 SCOPE POLICY

Implement only valid \`IN_SCOPE\` findings. Do not modify files to address
\`PRE_EXISTING\` findings. Report those findings under a distinct
\"Pre-existing issues noticed, not fixed\" heading with their ID, file, line,
severity, and suggested fix."
        [[ "$DRY_RUN" == "1" ]] && log_info \
            "Phase 4 scope policy: fix IN_SCOPE findings; flag PRE_EXISTING findings without applying them"
    fi

    local slot_a_review slot_b_review slot_a_cross slot_b_cross slot_a_meta slot_b_meta
    slot_a_review="$(review_artifact "$iteration" 1 "slot-a")"
    slot_b_review="$(review_artifact "$iteration" 1 "slot-b")"
    slot_a_cross="$(review_artifact "$iteration" 2 "slot-a")"
    slot_b_cross="$(review_artifact "$iteration" 2 "slot-b")"
    slot_a_meta="$(review_artifact "$iteration" 3 "slot-a")"
    slot_b_meta="$(review_artifact "$iteration" 3 "slot-b")"

    # Gather all artifacts
    local context="$synthesis_prompt

---
$execution_policy

---
$scope_policy

---
# ADVERSARIAL REVIEW CHAIN

## Phase 1: Independent Reviews

### Slot A ($SLOT_A) Review
$(cat "$slot_a_review")

### Slot B ($SLOT_B) Review
$(cat "$slot_b_review")

## Phase 2: Cross-Reviews

### Slot A ($SLOT_A) Analysis of Slot B ($SLOT_B)
$(cat "$slot_a_cross")

### Slot B ($SLOT_B) Analysis of Slot A ($SLOT_A)
$(cat "$slot_b_cross")

## Phase 3: Meta-Reviews

### Slot A ($SLOT_A) Response
$(cat "$slot_a_meta")

### Slot B ($SLOT_B) Response
$(cat "$slot_b_meta")

---
Working directory: $target_dir
"

    local output_file="$ARTIFACTS_DIR/iter${iteration}_4_synthesis.md"
    RESULT_FINAL_SYNTHESIS_ARTIFACT="$output_file"

    local fixer_agent="claude"
    local backend_mode="workspace-write"
    [[ "$EXECUTION_MODE" == "review-only" ]] && backend_mode="read-only"
    local fixer_rc=0
    local target_before=""
    [[ "$backend_mode" == "read-only" ]] && \
        target_before="$(target_tree_fingerprint "$target_dir")"
    if [[ "$FIXER" == "codex" ]]; then
        fixer_agent="codex"
        [[ "$DRY_RUN" == "1" ]] || RESULT_SYNTHESIS_EXECUTED_BY="$fixer_agent"
        log_info "Running Phase 4 synthesis with Codex ($backend_mode)"
        run_backend "codex" "$context" "$output_file" "$target_dir" \
            "$backend_mode" "phase_4" ||
            fixer_rc=$?
    else
        [[ "$DRY_RUN" == "1" ]] || RESULT_SYNTHESIS_EXECUTED_BY="$fixer_agent"
        log_info "Running Phase 4 synthesis with Claude ($backend_mode)"
        run_backend "claude" "$context" "$output_file" "$target_dir" \
            "$backend_mode" "phase_4" ||
            fixer_rc=$?
    fi
    if [[ "$backend_mode" == "read-only" ]] &&
       ! verify_review_target_unchanged "$iteration" "phase_4" "Phase 4" \
            "$target_dir" "$target_before"; then
        return "$PHASE_WRITE_BOUNDARY_VIOLATION"
    fi
    if [[ $fixer_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_4" "Phase 4" "$fixer_agent" \
            "agent exited with code $fixer_rc" "$output_file"
        if [[ $fixer_rc -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
            return "$PHASE_WRITE_BOUNDARY_VIOLATION"
        fi
        return "$PHASE_4_FAILED"
    fi

    [[ "$DRY_RUN" == "1" ]] && return "$PHASE_4_CONTINUE"

    local status
    if ! status="$(parse_status_block "$output_file" "SYNTHESIS_STATUS")"; then
        RESULT_TERMINATION_REASON="malformed-agent-response"
        record_agent_failure "$iteration" "phase_4" "Phase 4" "$fixer_agent" \
            "missing or malformed SYNTHESIS_STATUS block" "$output_file"
        return "$PHASE_4_FAILED"
    fi
    local exit_signal=$(echo "$status" | jq -r '.exit_signal // false')
    local files_modified=$(echo "$status" | jq -r '.files_modified // 0')
    local issues_skipped
    issues_skipped="$(echo "$status" | jq -r '.issues_skipped // 0')"
    local in_scope_fixed
    in_scope_fixed="$(echo "$status" | jq -r '.in_scope_fixed // 0')"
    local pre_existing_fixed
    pre_existing_fixed="$(echo "$status" | jq -r '.pre_existing_fixed // 0')"
    local pre_existing_flagged
    pre_existing_flagged="$(echo "$status" | jq -r '.pre_existing_flagged // 0')"
    local required_issue_ids
    # The issue-ledger protocol permits IDs to originate in Phase 1 or in
    # Phase 2 Additional Findings. Phase 3 only adjudicates those existing IDs,
    # so meta-review prose is intentionally excluded from the required-ID set.
    required_issue_ids="$(grep -Eoh \
        "(${slot_a_tag}|${slot_b_tag})-(ADD-)?[0-9]+" \
        "$slot_a_review" "$slot_b_review" "$slot_a_cross" "$slot_b_cross" |
        sort -u)"

    if [[ "$EXECUTION_MODE" == "review-only" ]] &&
       ! validate_review_only_synthesis "$output_file" "$status" \
            "$required_issue_ids"; then
        record_agent_failure "$iteration" "phase_4" "Phase 4" "$fixer_agent" \
            "review-only synthesis is missing required scope sections or claims fixes" \
            "$output_file"
        return "$PHASE_4_FAILED"
    fi

    add_to_history "$iteration" "phase_4" "$fixer_agent" "$status"
    update_tracking "in_scope_fixed" "$in_scope_fixed"
    update_tracking "pre_existing_fixed" "$pre_existing_fixed"
    update_tracking "pre_existing_flagged" "$pre_existing_flagged"
    RESULT_IN_SCOPE_FIXED="$in_scope_fixed"
    RESULT_PRE_EXISTING_FIXED="$pre_existing_fixed"
    RESULT_PRE_EXISTING_FLAGGED="$pre_existing_flagged"

    local synthesis_summary=$(echo "$status" | jq -r '.summary // "(no summary)"')
    log_info "Synthesis ($fixer_agent): $synthesis_summary"
    log_info "Synthesis scope counts: $in_scope_fixed in-scope fixed, $pre_existing_fixed pre-existing fixed, $pre_existing_flagged pre-existing flagged"

    # Record for circuit breaker
    local agents_agree=0
    # Check if both agents found similar issues
    local slot_a_meta_status=$(parse_status_block "$slot_a_meta" "META_REVIEW_STATUS" 2>/dev/null || echo '{}')
    local consensus=$(echo "$slot_a_meta_status" | jq -r '.consensus_reached // "NO"')
    [[ "$consensus" == "YES" || "$consensus" == "true" ]] && agents_agree=1

    local issues_hash=$(cat "$slot_a_review" "$slot_b_review" | shasum -a 256 | cut -d' ' -f1)

    record_iteration_result "$iteration" "$files_modified" "$agents_agree" "$issues_hash"

    if [[ "$exit_signal" == "true" ]]; then
        if [[ "$EXECUTION_MODE" == "review-only" ]]; then
            log_success "Read-only synthesis complete"
            if [[ $issues_skipped -gt 0 || $pre_existing_flagged -gt 0 ]]; then
                return "$PHASE_4_REVIEW_ONLY_FINDINGS"
            fi
        else
            log_success "Synthesis complete - no more issues"
            if [[ $issues_skipped -gt 0 || $pre_existing_flagged -gt 0 ]]; then
                return "$PHASE_4_APPLY_FIXES_FINDINGS"
            fi
        fi
        return "$PHASE_4_COMPLETE"
    fi

    if [[ "$EXECUTION_MODE" == "review-only" ]]; then
        log_info "Read-only synthesis incomplete, continuing review"
    else
        log_info "Fixes applied, will verify in next iteration"
    fi
    return "$PHASE_4_CONTINUE"
}

# ============================================================================
# Main Review Loop
# ============================================================================
run_review_loop() {
    local target_dir="$1"
    target_dir="$(cd "$target_dir" && pwd)"

    log_info "Starting Adversarial Review Loop"
    log_info "Target: $target_dir"
    log_info "Slot A reviewer: $SLOT_A"
    log_info "Slot B reviewer: $SLOT_B"
    log_info "Max iterations: $MAX_ITERATIONS"
    log_info "Timeout: ${TIMEOUT_MINUTES}m per agent"
    if [[ -n "$BASE_REF" ]]; then
        log_info "Scope: base-scoped ($BASE_REF)"
    else
        log_info "Scope: whole-directory"
    fi
    echo ""

    log_verbose "Initializing tracking..."
    init_tracking
    log_verbose "Initializing circuit breaker..."
    init_circuit_breaker

    log_verbose "Updating tracking state..."
    update_tracking "target_dir" "$target_dir"
    update_tracking "slot_a" "$SLOT_A"
    update_tracking "slot_b" "$SLOT_B"
    update_tracking "base_ref" "${BASE_REF:-whole-directory}"
    update_tracking "include_pre_existing" "$([[ "$INCLUDE_PRE_EXISTING" == "1" ]] && echo true || echo false)"
    update_tracking "execution_mode" "$EXECUTION_MODE"
    update_tracking "status" "in_progress"
    update_tracking "started_at" "$(get_iso_timestamp)"

    local iteration=0
    log_verbose "Starting main loop (MAX_ITERATIONS=$MAX_ITERATIONS)..."

    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        ((iteration++)) || true
        RESULT_ITERATIONS="$iteration"
        log_info "=== Entering iteration $iteration ==="
        update_tracking "iteration" "$iteration"

        # Check circuit breaker
        if ! can_execute; then
            log_error "Circuit breaker is OPEN - halting"
            show_circuit_status
            update_tracking "status" "circuit_open"
            RESULT_TERMINATION_REASON="circuit-open"
            return "$EXIT_INCOMPLETE_REVIEW"
        fi

        echo ""
        log_info "=========================================="
        log_info "ITERATION $iteration / $MAX_ITERATIONS"
        log_info "=========================================="
        echo ""

        # Phase 1
        [[ "$DRY_RUN" == "1" ]] || RESULT_REVIEW_EXECUTED=true
        local phase_1_result=0
        run_phase_1 "$target_dir" "$iteration" || phase_1_result=$?
        if [[ $phase_1_result -eq $PHASE_1_CLEAN ]]; then
            if [[ "$EXECUTION_MODE" == "review-only" ]]; then
                log_info "Both Phase 1 reviewers reported clean; continuing all review-only phases"
            else
                log_success "Review complete - both agents report clean code"
                update_tracking "status" "clean"
                RESULT_TERMINATION_REASON="clean-phase-1"
                return "$EXIT_CLEAN"
            fi
        elif [[ $phase_1_result -ne $PHASE_1_CONTINUE ]]; then
            if [[ $phase_1_result -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
                RESULT_TERMINATION_REASON="write-boundary-violation"
            fi
            return "$(map_phase_failure_exit "$phase_1_result")"
        fi
        echo ""

        # Phase 2
        local phase_2_result=0
        run_phase_2 "$target_dir" "$iteration" || phase_2_result=$?
        if [[ $phase_2_result -ne 0 ]]; then
            if [[ $phase_2_result -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
                RESULT_TERMINATION_REASON="write-boundary-violation"
            fi
            return "$(map_phase_failure_exit "$phase_2_result")"
        fi
        echo ""

        # Phase 3
        local phase_3_result=0
        run_phase_3 "$target_dir" "$iteration" || phase_3_result=$?
        if [[ $phase_3_result -ne 0 ]]; then
            if [[ $phase_3_result -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
                RESULT_TERMINATION_REASON="write-boundary-violation"
            fi
            return "$(map_phase_failure_exit "$phase_3_result")"
        fi
        echo ""

        # Phase 4
        local phase_4_result=0
        run_phase_4 "$target_dir" "$iteration" || phase_4_result=$?
        if [[ $phase_4_result -eq $PHASE_4_COMPLETE ]]; then
            if [[ "$EXECUTION_MODE" == "review-only" ]]; then
                log_success "Review-only synthesis complete"
                update_tracking "status" "review_complete"
            else
                log_success "Synthesis complete"
                update_tracking "status" "clean"
            fi
            RESULT_TERMINATION_REASON="clean-synthesis"
            return "$EXIT_CLEAN"
        elif [[ $phase_4_result -eq $PHASE_4_REVIEW_ONLY_FINDINGS ]]; then
            log_warning "Review-only completed with unresolved findings"
            update_tracking "status" "review_complete_findings"
            RESULT_TERMINATION_REASON="review-only-findings-remain"
            return "$EXIT_REVIEW_ONLY_FINDINGS"
        elif [[ $phase_4_result -eq $PHASE_4_APPLY_FIXES_FINDINGS ]]; then
            log_warning "Apply-fixes completed with unresolved findings"
            update_tracking "status" "fixes_complete_findings"
            RESULT_TERMINATION_REASON="apply-fixes-findings-remain"
            return "$EXIT_APPLY_FIXES_FINDINGS"
        elif [[ $phase_4_result -eq $PHASE_4_FAILED ]]; then
            return "$EXIT_AGENT_BACKEND_FAILURE"
        elif [[ $phase_4_result -eq $PHASE_WRITE_BOUNDARY_VIOLATION ]]; then
            RESULT_TERMINATION_REASON="write-boundary-violation"
            return "$EXIT_WRITE_BOUNDARY_VIOLATION"
        fi
        echo ""

        log_info "Iteration $iteration complete, will verify fixes..."
        sleep 2
    done

    log_warning "Reached max iterations ($MAX_ITERATIONS)"
    update_tracking "status" "max_iterations"
    RESULT_TERMINATION_REASON="max-iterations"
    return "$EXIT_INCOMPLETE_REVIEW"
}

# ============================================================================
# Status & Management Commands
# ============================================================================
show_status() {
    echo ""
    log_info "=== Adversarial Review Status ==="
    log_info "State dir: $AR_DIR"
    log_info "Slot A reviewer: $SLOT_A"
    log_info "Slot B reviewer: $SLOT_B"
    echo ""

    if [[ ! -f "$TRACKING_FILE" ]]; then
        echo "No tracking file found for this target. Run a review against it first."
        return
    fi

    jq -r '
        "Target:     \(.target_dir // "none")",
        "Slot A:     \(.slot_a // "unknown")",
        "Slot B:     \(.slot_b // "unknown")",
        "Scope:      \(.base_ref // "whole-directory")",
        "Execution mode:       \(.execution_mode // "apply-fixes")",
        "Pre-existing fixes: \(if .execution_mode == "review-only" then "report only" elif .include_pre_existing then "included" else "report only" end)",
        "In-scope fixed:     \(.in_scope_fixed // 0)",
        "Pre-existing fixed: \(.pre_existing_fixed // 0)",
        "Pre-existing flagged: \(.pre_existing_flagged // 0)",
        "Status:     \(.status // "unknown")",
        "Iteration:  \(.iteration // 0)",
        "Started:    \(.started_at // "never")",
        "Updated:    \(.updated_at // "never")",
        "",
        "Recent History:"
    ' "$TRACKING_FILE"

    jq -r '.history | if length == 0 then "  (none)" else .[-10:] | .[] | "  - Iter \(.iteration) \(.phase) [\(.agent)]: \(.result | if type == "object" then .summary // "ok" else . end)"  end' "$TRACKING_FILE" 2>/dev/null || echo "  (none)"

    echo ""
    echo "Artifacts:"
    if [[ -d "$ARTIFACTS_DIR" ]] && [[ -n "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ]]; then
        ls -1 "$ARTIFACTS_DIR" | head -20 | while read -r f; do
            echo "  $f"
        done
    else
        echo "  (none)"
    fi
}

reset_all() {
    log_info "Resetting all state for: $AR_DIR"
    rm -rf "$ARTIFACTS_DIR"/* "$TRACKING_FILE"
    rm -f "$AR_DIR/.circuit_breaker.json" "$AR_DIR/.circuit_breaker_history.json"
    rm -f "$AR_DIR/.response_analysis.json"
    mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"
    init_tracking
    init_circuit_breaker
    log_success "Reset complete"
}

show_help() {
    cat << 'EOF'
Adversarial Review: Multi-Agent Code Review with Claude + Codex

USAGE:
    ./adversarial_review.sh [OPTIONS] <slot_a> <slot_b> <target_directory>
    ./adversarial_review.sh [OPTIONS] --slot-a AGENT --slot-b AGENT --target-dir PATH

OPTIONS:
    -h, --help              Show this help
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Add Phase 1 review criteria for this run only;
                            preserves the mandatory built-in output protocol
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    -f, --fixer AGENT       Who implements Phase 4 fixes: claude | codex
                            (if omitted, prompts interactively on a TTY;
                            defaults to codex when non-interactive)
    --slot-a AGENT          Backend for reviewer slot A: claude | codex
    --slot-b AGENT          Backend for reviewer slot B: claude | codex
    --target-dir PATH       Project directory to review
    -b, --base REF          Review only files differing from this git ref,
                            including uncommitted and untracked source files
    --include-pre-existing  Allow Phase 4 to fix PRE_EXISTING findings too
                            (default: report them without applying changes)
    --review-only           Run Phase 4 through the same read-only backend
                            path as Phases 1-3. Synthesis reports unresolved
                            IN_SCOPE and PRE_EXISTING findings without
                            modifying the target (mutually exclusive with
                            --apply-fixes).
    --apply-fixes           Declare that this caller wants (and accepts)
                            Phase 4 keeping today's write-access behavior
                            (mutually exclusive with --review-only)
                            If neither --review-only nor --apply-fixes is
                            given, Phase 4 behavior matches today's implicit
                            apply-fixes default, and a migration warning is
                            printed. Passing both is a startup error. New
                            automation, skills, and plugins should pass one
                            of these flags explicitly, since the implicit
                            default may be removed in a future version.
    --result-file PATH      Atomically write one schema-versioned JSON result
                            when the invocation terminates
    --status                Show current status for the required target
    --reset                 Reset all state for the required target
    --reset-circuit         Reset circuit breaker for the required target
    --circuit-status        Show circuit breaker status for the required target
    --dry-run               Show what would happen without executing

EXIT STATUSES:
    0   Clean review (management-command success also remains 0)
    10  Review-only completed with unresolved findings
    11  Apply-fixes completed with unresolved or pre-existing findings
    12  Incomplete review (max iterations or open circuit breaker)
    64  Invalid invocation rejected before Agent execution
    70  Agent/backend unavailable, failed, timed out, or malformed response
    77  Read-only write-boundary violation

STATE:
    All state (tracking.json, circuit breaker, artifacts/) is scoped per
    target directory under state/<slug>/, so reviewing one project can't
    pollute or trip a circuit breaker for another. Pass the same target
    slot assignments and target directory to --status/--reset/etc. to scope
    to that project.

PHASES:
    1. Independent Review   Slot A and slot B review code in parallel
    2. Cross-Review         Each reviews the other's findings
    3. Meta-Review          Each reviews feedback on their review
    4. Synthesis            Claude or Codex synthesizes and implements fixes

CIRCUIT BREAKER:
    Prevents runaway loops by detecting:
    - No progress after 3 iterations
    - Persistent disagreement (5+ iterations)
    - Same issues found 3+ times (unfixable)

REQUIREMENTS:
    - claude CLI: npm install -g @anthropic-ai/claude-code
    - codex CLI: npm install -g @openai/codex
    - jq: brew install jq
    - coreutils (macOS): brew install coreutils (for timeout)

EXAMPLES:
    ./adversarial_review.sh claude codex ../my-project
    ./adversarial_review.sh --slot-a codex --slot-b claude --target-dir ../my-project
    ./adversarial_review.sh codex --slot-b claude --target-dir ../my-project
    ./adversarial_review.sh --dry-run claude codex ../my-project
    ./adversarial_review.sh --status claude codex ../my-project

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
    local target_dir=""
    local custom_prompt=""
    local action="review"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -m|--max-iters)
                [[ $# -ge 2 ]] || { log_error "Missing value for $1"; exit "$EXIT_INVALID_INVOCATION"; }
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -p|--prompt)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $1"
                    exit "$EXIT_INVALID_INVOCATION"
                fi
                custom_prompt="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -t|--timeout)
                [[ $# -ge 2 ]] || { log_error "Missing value for $1"; exit "$EXIT_INVALID_INVOCATION"; }
                TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            -f|--fixer)
                [[ $# -ge 2 ]] || { log_error "Missing value for $1"; exit "$EXIT_INVALID_INVOCATION"; }
                FIXER="$2"
                shift 2
                ;;
            --slot-a)
                [[ $# -ge 2 ]] || { log_error "Missing value for $1"; exit "$EXIT_INVALID_INVOCATION"; }
                [[ -z "$SLOT_A" ]] || { log_error "slot-a was specified more than once"; exit "$EXIT_INVALID_INVOCATION"; }
                SLOT_A="$2"
                shift 2
                ;;
            --slot-b)
                [[ $# -ge 2 ]] || { log_error "Missing value for $1"; exit "$EXIT_INVALID_INVOCATION"; }
                [[ -z "$SLOT_B" ]] || { log_error "slot-b was specified more than once"; exit "$EXIT_INVALID_INVOCATION"; }
                SLOT_B="$2"
                shift 2
                ;;
            --target-dir)
                [[ $# -ge 2 ]] || { log_error "Missing value for $1"; exit "$EXIT_INVALID_INVOCATION"; }
                [[ -z "$target_dir" ]] || { log_error "target-dir was specified more than once"; exit "$EXIT_INVALID_INVOCATION"; }
                target_dir="$2"
                shift 2
                ;;
            -b|--base)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $1"
                    exit "$EXIT_INVALID_INVOCATION"
                fi
                BASE_REF="$2"
                shift 2
                ;;
            --include-pre-existing)
                INCLUDE_PRE_EXISTING=1
                shift
                ;;
            --review-only)
                REVIEW_ONLY=1
                shift
                ;;
            --apply-fixes)
                APPLY_FIXES=1
                shift
                ;;
            --result-file)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $1"
                    exit "$EXIT_INVALID_INVOCATION"
                fi
                if [[ "$RESULT_FILE_SEEN" == "1" ]]; then
                    RESULT_TERMINATION_REASON="invalid-result-file"
                    log_error "--result-file was specified more than once"
                    exit "$EXIT_INVALID_INVOCATION"
                fi
                RESULT_FILE="$2"
                RESULT_FILE_SEEN=1
                shift 2
                ;;
            --status)
                action="status"
                shift
                ;;
            --reset)
                action="reset"
                shift
                ;;
            --reset-circuit)
                action="reset-circuit"
                shift
                ;;
            --circuit-status)
                action="circuit-status"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit "$EXIT_INVALID_INVOCATION"
                ;;
            *)
                if [[ -z "$SLOT_A" ]]; then
                    SLOT_A="$1"
                elif [[ -z "$SLOT_B" ]]; then
                    SLOT_B="$1"
                elif [[ -z "$target_dir" ]]; then
                    target_dir="$1"
                else
                    log_error "Unexpected positional argument: $1"
                    exit "$EXIT_INVALID_INVOCATION"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$SLOT_A" ]]; then
        log_error "No slot-a backend specified (expected 'claude' or 'codex')"
        exit "$EXIT_INVALID_INVOCATION"
    fi
    if [[ -z "$SLOT_B" ]]; then
        log_error "No slot-b backend specified (expected 'claude' or 'codex'); the old single-positional form is no longer supported"
        exit "$EXIT_INVALID_INVOCATION"
    fi
    if [[ -z "$target_dir" ]]; then
        log_error "No target directory specified (use positional 3 or --target-dir)"
        echo ""
        show_help
        exit "$EXIT_INVALID_INVOCATION"
    fi

    if [[ "$SLOT_A" != "claude" && "$SLOT_A" != "codex" ]]; then
        log_error "Invalid slot-a backend: $SLOT_A (must be 'claude' or 'codex')"
        exit "$EXIT_INVALID_INVOCATION"
    fi
    if [[ "$SLOT_B" != "claude" && "$SLOT_B" != "codex" ]]; then
        log_error "Invalid slot-b backend: $SLOT_B (must be 'claude' or 'codex')"
        exit "$EXIT_INVALID_INVOCATION"
    fi

    if [[ "$SLOT_A" == "$SLOT_B" ]]; then
        log_warning "Both reviewer slots use '$SLOT_A'; reduced review diversity is expected"
    fi

    if [[ ! -d "$target_dir" ]]; then
        log_error "Directory does not exist: $target_dir"
        exit "$EXIT_INVALID_INVOCATION"
    fi

    capture_result_target_identity "$target_dir"

    case "$action" in
        status) show_status; exit 0 ;;
        reset) reset_all; exit 0 ;;
        reset-circuit)
            init_circuit_breaker
            reset_circuit_breaker "Manual reset"
            exit 0
            ;;
        circuit-status)
            init_circuit_breaker
            show_circuit_status
            exit 0
            ;;
    esac

    if [[ ! "$MAX_ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Invalid --max-iters value: $MAX_ITERATIONS (must be a positive integer)"
        exit "$EXIT_INVALID_INVOCATION"
    fi
    if [[ ! "$TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Invalid --timeout value: $TIMEOUT_MINUTES (must be a positive integer)"
        exit "$EXIT_INVALID_INVOCATION"
    fi

    if [[ "$REVIEW_ONLY" == "1" && "$APPLY_FIXES" == "1" ]]; then
        log_error "--review-only and --apply-fixes are mutually exclusive"
        exit "$EXIT_INVALID_INVOCATION"
    elif [[ "$REVIEW_ONLY" != "1" && "$APPLY_FIXES" != "1" ]]; then
        log_warning "Neither --review-only nor --apply-fixes was specified; using today's implicit Phase 4 behavior (write access is kept). This implicit default may be removed in a future version — automation, skills, and plugins invoking this CLI should pass one of the two flags explicitly."
    fi
    [[ "$REVIEW_ONLY" == "1" ]] && EXECUTION_MODE="review-only"

    if [[ -n "$BASE_REF" ]]; then
        if [[ "$(git -C "$target_dir" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
            RESULT_TERMINATION_REASON="invalid-base-ref"
            log_error "Cannot use --base: target is not a git working tree: $target_dir"
            exit "$EXIT_INVALID_INVOCATION"
        fi

        if ! BASE_COMMIT="$(git -C "$target_dir" rev-parse --verify --quiet --end-of-options "${BASE_REF}^{commit}")"; then
            RESULT_TERMINATION_REASON="invalid-base-ref"
            log_error "Base ref '$BASE_REF' does not resolve to a commit in target: $target_dir"
            exit "$EXIT_INVALID_INVOCATION"
        fi

        local scoped_files
        scoped_files="$(collect_file_list "$target_dir" "$BASE_COMMIT")"
        if [[ -z "$scoped_files" ]]; then
            RESULT_TERMINATION_REASON="empty-base-scope"
            log_error "No reviewable files differ from base '$BASE_REF'"
            exit "$EXIT_INVALID_INVOCATION"
        fi
    fi

    if [[ -n "$custom_prompt" ]]; then
        if [[ ! -f "$custom_prompt" ]]; then
            log_error "Custom prompt is not a regular file: $custom_prompt"
            exit "$EXIT_INVALID_INVOCATION"
        fi
        if [[ ! -r "$custom_prompt" ]]; then
            log_error "Custom prompt is not readable: $custom_prompt"
            exit "$EXIT_INVALID_INVOCATION"
        fi
        if ! CUSTOM_REVIEW_CRITERIA="$(< "$custom_prompt")"; then
            log_error "Could not read custom prompt: $custom_prompt"
            exit "$EXIT_INVALID_INVOCATION"
        fi
        log_info "Using additional review criteria: $custom_prompt"
    fi

    if [[ -z "$FIXER" ]]; then
        if [[ "$DRY_RUN" == "1" || ! -t 0 ]]; then
            FIXER="codex"
        else
            local choice
            read -r -p "$(echo -e "${BLUE}[INFO]${NC} Which agent should implement fixes in Phase 4? [c]laude / [x]codex (default: codex): ")" choice
            case "$choice" in
                c|C|claude) FIXER="claude" ;;
                *) FIXER="codex" ;;
            esac
        fi
    fi

    if [[ "$FIXER" != "claude" && "$FIXER" != "codex" ]]; then
        log_error "Invalid --fixer value: $FIXER (must be 'claude' or 'codex')"
        exit "$EXIT_INVALID_INVOCATION"
    fi

    check_dependencies

    if [[ "$DRY_RUN" != "1" ]]; then
        RESULT_TARGET_SNAPSHOT="$(mktemp)"
        target_file_manifest "$RESULT_TARGET_DIR" > "$RESULT_TARGET_SNAPSHOT"
    fi

    if [[ "$EXECUTION_MODE" == "review-only" ]]; then
        log_info "Phase 4 synthesis will run read-only with: $FIXER"
    else
        log_info "Phase 4 fixes will be implemented by: $FIXER"
    fi

    run_review_loop "$target_dir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap on_process_exit EXIT
    main "$@"
fi
