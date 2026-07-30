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
#   ./adversarial_review.sh [OPTIONS] <target_dir>
#
# Options:
#   -h, --help              Show help message
#   -m, --max-iters N       Maximum iterations (default: 3)
#   -p, --prompt FILE       Additional Phase 1 review criteria file
#   -v, --verbose           Verbose output
#   -t, --timeout MIN       Timeout per agent call in minutes (default: 10)
#   -f, --fixer AGENT       Who implements Phase 4 fixes: claude | codex
#   -b, --base REF          Review only files differing from this git ref
#   --include-pre-existing  Allow Phase 4 to fix PRE_EXISTING findings
#   --status [DIR]          Show current status (scoped to DIR if given)
#   --reset [DIR]           Reset artifacts and tracking (scoped to DIR if given)
#   --reset-circuit [DIR]   Reset circuit breaker (scoped to DIR if given)
#   --circuit-status [DIR]  Show circuit breaker status (scoped to DIR if given)
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

_prescan_target_dir=""
_prescan_args=("$@")
_prescan_i=0
while [[ $_prescan_i -lt ${#_prescan_args[@]} ]]; do
    _arg="${_prescan_args[$_prescan_i]}"
    case "$_arg" in
        -m|--max-iters|-p|--prompt|-t|--timeout|-f|--fixer|-b|--base)
            ((_prescan_i+=2)) || true
            ;;
        -h|--help|-v|--verbose|--status|--reset|--reset-circuit|--circuit-status|--dry-run|--include-pre-existing)
            ((_prescan_i+=1)) || true
            ;;
        -*)
            ((_prescan_i+=1)) || true
            ;;
        *)
            _prescan_target_dir="$_arg"
            break
            ;;
    esac
done
unset _prescan_args _prescan_i _arg

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
BASE_REF=""
BASE_COMMIT=""
INCLUDE_PRE_EXISTING=0
CUSTOM_REVIEW_CRITERIA=""
REVIEW_AVAILABLE_TOOLS="Read Glob Grep Bash"
REVIEW_ALLOWED_TOOLS="Read Glob Grep Bash(git log *) Bash(git blame *)"

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

    log_error "$phase_label $agent failed: $detail (artifact: $artifact)"
    update_tracking "status" "agent_failed"
    agent_key="$(printf '%s' "$agent" | tr '[:upper:]' '[:lower:]')"
    result="$(jq -cn \
        --arg error "$detail" \
        --arg artifact "$artifact" \
        '{error: $error, artifact: $artifact}')"
    add_to_history "$iteration" "$phase_key" "$agent_key" "$result"
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

    if ! command -v claude &> /dev/null; then
        missing+=("claude CLI (npm install -g @anthropic-ai/claude-code)")
    fi

    if ! command -v codex &> /dev/null; then
        missing+=("codex CLI (npm install -g @openai/codex)")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq (brew install jq)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
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
    "base_ref": null,
    "include_pre_existing": false,
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
            "result": ($r | fromjson? // $r),
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
        )
    fi

    local exit_code=0
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && printf '%s\n' "$prompt" | $timeout_cmd ${timeout_secs}s claude "${cmd_args[@]}") > "$output_file" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && printf '%s\n' "$prompt" | claude "${cmd_args[@]}") > "$output_file" 2>&1 || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_claude "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
    elif [[ $exit_code -eq 124 ]]; then
        log_warning "Claude timed out after ${TIMEOUT_MINUTES}m"
    else
        log_warning "Claude exited with code $exit_code"
    fi

    return $exit_code
}

# Run Codex
run_codex() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"
    local sandbox_mode="${4:-read-only}"

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

    local exit_code=0
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && printf '%s\n' "$prompt" | $timeout_cmd ${timeout_secs}s codex exec -s "$sandbox_mode" --skip-git-repo-check -o "$output_file") > "$raw_log" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && printf '%s\n' "$prompt" | codex exec -s "$sandbox_mode" --skip-git-repo-check -o "$output_file") > "$raw_log" 2>&1 || exit_code=$?
    fi

    # If codex failed before writing a final message (crash, timeout), fall
    # back to the raw transcript so callers still have something to parse.
    if [[ ! -s "$output_file" ]]; then
        cp "$raw_log" "$output_file"
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_codex "Complete ($(wc -l < "$output_file" | tr -d ' ') lines, raw transcript $(wc -l < "$raw_log" | tr -d ' ') lines)"
    elif [[ $exit_code -eq 124 ]]; then
        log_warning "Codex timed out after ${TIMEOUT_MINUTES}m"
    else
        log_warning "Codex exited with code $exit_code"
    fi

    return $exit_code
}

# Both agents number their issues starting from 1 in every phase; without
# telling each one which agent it is, their IDs collide (both produce
# ISSUE-1, ISSUE-2, ...) once merged in cross-review/meta-review/synthesis.
# Prepended to each agent's own prompt variant so it prefixes its IDs with
# a globally-unique agent tag instead.
agent_id_header() {
    local agent_tag="$1"
    echo "# YOUR AGENT ID: ${agent_tag}

Prefix every issue ID you produce in this response with this tag, e.g.
\`${agent_tag}-1\`, \`${agent_tag}-2\`, ... The other agent is reviewing the
same code independently and will use a different tag, so these IDs must
stay globally unique once both of your findings are merged together in
later phases."
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

    local claude_prompt="$(agent_id_header "CLAUDE")

$common_prompt"
    local codex_prompt="$(agent_id_header "CODEX")

$common_prompt"

    local claude_out="$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md"
    local codex_out="$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md"

    # Run in parallel
    run_claude "$claude_prompt" "$claude_out" "$target_dir" "false" \
        "$REVIEW_AVAILABLE_TOOLS" \
        "$REVIEW_ALLOWED_TOOLS" &
    local claude_pid=$!

    run_codex "$codex_prompt" "$codex_out" "$target_dir" &
    local codex_pid=$!

    local claude_rc=0
    local codex_rc=0
    wait "$claude_pid" || claude_rc=$?
    wait "$codex_pid" || codex_rc=$?

    if [[ $claude_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_1" "Phase 1" "Claude" \
            "agent exited with code $claude_rc" "$claude_out"
    fi
    if [[ $codex_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_1" "Phase 1" "Codex" \
            "agent exited with code $codex_rc" "$codex_out"
    fi
    [[ $claude_rc -eq 0 && $codex_rc -eq 0 ]] || return 2

    [[ "$DRY_RUN" == "1" ]] && return 1

    # Parse results
    local claude_status
    local codex_status
    if ! claude_status="$(parse_status_block "$claude_out" "REVIEW_STATUS")"; then
        record_agent_failure "$iteration" "phase_1" "Phase 1" "Claude" \
            "missing or malformed REVIEW_STATUS block" "$claude_out"
        return 2
    fi
    if ! codex_status="$(parse_status_block "$codex_out" "REVIEW_STATUS")"; then
        record_agent_failure "$iteration" "phase_1" "Phase 1" "Codex" \
            "missing or malformed REVIEW_STATUS block" "$codex_out"
        return 2
    fi
    log_scope_errors "$claude_status" "Phase 1 Claude"
    log_scope_errors "$codex_status" "Phase 1 Codex"

    local claude_exit=$(echo "$claude_status" | jq -r '.exit_signal // false')
    local codex_exit=$(echo "$codex_status" | jq -r '.exit_signal // false')

    add_to_history "$iteration" "phase_1" "claude" "$claude_status"
    add_to_history "$iteration" "phase_1" "codex" "$codex_status"

    # Check for dual NO_ISSUES
    if [[ "$claude_exit" == "true" ]] && [[ "$codex_exit" == "true" ]]; then
        log_success "Both agents report NO_ISSUES"
        return 0  # Signal clean exit
    fi

    local claude_issues=$(echo "$claude_status" | jq -r '.issues_found // 0')
    local codex_issues=$(echo "$codex_status" | jq -r '.issues_found // 0')
    local claude_summary=$(echo "$claude_status" | jq -r '.summary // "(no summary)"')
    local codex_summary=$(echo "$codex_status" | jq -r '.summary // "(no summary)"')

    log_info "Claude found: $claude_issues issues - $claude_summary"
    log_info "Codex found: $codex_issues issues - $codex_summary"

    return 1  # Continue to next phase
}

# ============================================================================
# PHASE 2: Cross-Review
# ============================================================================
run_phase_2() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 2: Cross-Review ==="

    local claude_review="$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md"
    local codex_review="$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md"

    local cross_prompt=$(cat "$PROMPTS_DIR/cross_review.md")

    # Claude reviews Codex
    local claude_prompt="$(agent_id_header "CLAUDE")

$cross_prompt

---
# THE OTHER AGENT'S REVIEW TO ANALYZE

$(cat "$codex_review")
"

    # Codex reviews Claude
    local codex_prompt="$(agent_id_header "CODEX")

$cross_prompt

---
# THE OTHER AGENT'S REVIEW TO ANALYZE

$(cat "$claude_review")
"

    local claude_out="$ARTIFACTS_DIR/iter${iteration}_2_claude_on_codex.md"
    local codex_out="$ARTIFACTS_DIR/iter${iteration}_2_codex_on_claude.md"

    run_claude "$claude_prompt" "$claude_out" "$target_dir" "false" \
        "$REVIEW_AVAILABLE_TOOLS" \
        "$REVIEW_ALLOWED_TOOLS" &
    local claude_pid=$!

    run_codex "$codex_prompt" "$codex_out" "$target_dir" &
    local codex_pid=$!

    local claude_rc=0
    local codex_rc=0
    wait "$claude_pid" || claude_rc=$?
    wait "$codex_pid" || codex_rc=$?

    if [[ $claude_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_2" "Phase 2" "Claude" \
            "agent exited with code $claude_rc" "$claude_out"
    fi
    if [[ $codex_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_2" "Phase 2" "Codex" \
            "agent exited with code $codex_rc" "$codex_out"
    fi
    [[ $claude_rc -eq 0 && $codex_rc -eq 0 ]] || return 1

    [[ "$DRY_RUN" == "1" ]] && return 0

    local claude_status
    local codex_status
    if ! claude_status="$(parse_status_block "$claude_out" "CROSS_REVIEW_STATUS")"; then
        record_agent_failure "$iteration" "phase_2" "Phase 2" "Claude" \
            "missing or malformed CROSS_REVIEW_STATUS block" "$claude_out"
        return 1
    fi
    if ! codex_status="$(parse_status_block "$codex_out" "CROSS_REVIEW_STATUS")"; then
        record_agent_failure "$iteration" "phase_2" "Phase 2" "Codex" \
            "missing or malformed CROSS_REVIEW_STATUS block" "$codex_out"
        return 1
    fi
    log_scope_errors "$claude_status" "Phase 2 Claude"
    log_scope_errors "$codex_status" "Phase 2 Codex"

    add_to_history "$iteration" "phase_2" "claude" "$claude_status"
    add_to_history "$iteration" "phase_2" "codex" "$codex_status"

    local claude_summary=$(echo "$claude_status" | jq -r '.summary // "(no summary)"')
    local codex_summary=$(echo "$codex_status" | jq -r '.summary // "(no summary)"')

    log_info "Claude on Codex's review: $claude_summary"
    log_info "Codex on Claude's review: $codex_summary"

    log_success "Cross-review complete"
}

# ============================================================================
# PHASE 3: Meta-Review
# ============================================================================
run_phase_3() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 3: Meta-Review ==="

    local codex_on_claude="$ARTIFACTS_DIR/iter${iteration}_2_codex_on_claude.md"
    local claude_on_codex="$ARTIFACTS_DIR/iter${iteration}_2_claude_on_codex.md"
    local claude_review="$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md"
    local codex_review="$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md"

    local meta_prompt=$(cat "$PROMPTS_DIR/meta_review.md")

    # Each phase runs as a fresh, stateless CLI invocation with no memory of
    # earlier phases, so the meta-review prompt has to re-supply everything
    # needed to reach a full consensus: both agents' original Phase 1
    # findings AND this agent's own Phase 2 verdicts on the other agent's
    # findings - not just the feedback the other agent gave back. Without
    # this, an agent has no way to rule on the other side's issues at all in
    # Phase 3, and they silently vanish from the consensus list.

    # Claude responds to Codex's feedback, with full context restored
    local claude_prompt="$(agent_id_header "CLAUDE")

$meta_prompt

---
# YOUR ORIGINAL REVIEW (Phase 1)

$(cat "$claude_review")

---
# THE OTHER AGENT'S ORIGINAL REVIEW (Phase 1)

$(cat "$codex_review")

---
# YOUR OWN CROSS-REVIEW OF THEIR FINDINGS (Phase 2)

$(cat "$claude_on_codex")

---
# FEEDBACK ON YOUR ORIGINAL REVIEW (Phase 2)

$(cat "$codex_on_claude")
"

    # Codex responds to Claude's feedback, with full context restored
    local codex_prompt="$(agent_id_header "CODEX")

$meta_prompt

---
# YOUR ORIGINAL REVIEW (Phase 1)

$(cat "$codex_review")

---
# THE OTHER AGENT'S ORIGINAL REVIEW (Phase 1)

$(cat "$claude_review")

---
# YOUR OWN CROSS-REVIEW OF THEIR FINDINGS (Phase 2)

$(cat "$codex_on_claude")

---
# FEEDBACK ON YOUR ORIGINAL REVIEW (Phase 2)

$(cat "$claude_on_codex")
"

    local claude_out="$ARTIFACTS_DIR/iter${iteration}_3_claude_meta.md"
    local codex_out="$ARTIFACTS_DIR/iter${iteration}_3_codex_meta.md"

    run_claude "$claude_prompt" "$claude_out" "$target_dir" "false" \
        "$REVIEW_AVAILABLE_TOOLS" \
        "$REVIEW_ALLOWED_TOOLS" &
    local claude_pid=$!

    run_codex "$codex_prompt" "$codex_out" "$target_dir" &
    local codex_pid=$!

    local claude_rc=0
    local codex_rc=0
    wait "$claude_pid" || claude_rc=$?
    wait "$codex_pid" || codex_rc=$?

    if [[ $claude_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_3" "Phase 3" "Claude" \
            "agent exited with code $claude_rc" "$claude_out"
    fi
    if [[ $codex_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_3" "Phase 3" "Codex" \
            "agent exited with code $codex_rc" "$codex_out"
    fi
    [[ $claude_rc -eq 0 && $codex_rc -eq 0 ]] || return 1

    [[ "$DRY_RUN" == "1" ]] && return 0

    local claude_status
    local codex_status
    if ! claude_status="$(parse_status_block "$claude_out" "META_REVIEW_STATUS")"; then
        record_agent_failure "$iteration" "phase_3" "Phase 3" "Claude" \
            "missing or malformed META_REVIEW_STATUS block" "$claude_out"
        return 1
    fi
    if ! codex_status="$(parse_status_block "$codex_out" "META_REVIEW_STATUS")"; then
        record_agent_failure "$iteration" "phase_3" "Phase 3" "Codex" \
            "missing or malformed META_REVIEW_STATUS block" "$codex_out"
        return 1
    fi
    log_scope_errors "$claude_status" "Phase 3 Claude"
    log_scope_errors "$codex_status" "Phase 3 Codex"

    add_to_history "$iteration" "phase_3" "claude" "$claude_status"
    add_to_history "$iteration" "phase_3" "codex" "$codex_status"

    local claude_summary=$(echo "$claude_status" | jq -r '.summary // "(no summary)"')
    local codex_summary=$(echo "$codex_status" | jq -r '.summary // "(no summary)"')

    log_info "Claude meta-review: $claude_summary"
    log_info "Codex meta-review: $codex_summary"

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
    local scope_policy
    if [[ "$INCLUDE_PRE_EXISTING" == "1" ]]; then
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

    # Gather all artifacts
    local context="$synthesis_prompt

---
$scope_policy

---
# ADVERSARIAL REVIEW CHAIN

## Phase 1: Independent Reviews

### Claude's Review
$(cat "$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md")

### Codex's Review
$(cat "$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md")

## Phase 2: Cross-Reviews

### Claude's Analysis of Codex
$(cat "$ARTIFACTS_DIR/iter${iteration}_2_claude_on_codex.md")

### Codex's Analysis of Claude
$(cat "$ARTIFACTS_DIR/iter${iteration}_2_codex_on_claude.md")

## Phase 3: Meta-Reviews

### Claude's Response
$(cat "$ARTIFACTS_DIR/iter${iteration}_3_claude_meta.md")

### Codex's Response
$(cat "$ARTIFACTS_DIR/iter${iteration}_3_codex_meta.md")

---
Working directory: $target_dir
"

    local output_file="$ARTIFACTS_DIR/iter${iteration}_4_synthesis.md"

    local fixer_agent="claude"
    local fixer_rc=0
    if [[ "$FIXER" == "codex" ]]; then
        fixer_agent="codex"
        log_info "Implementing fixes with Codex (workspace-write)"
        run_codex "$context" "$output_file" "$target_dir" "workspace-write" ||
            fixer_rc=$?
    else
        run_claude "$context" "$output_file" "$target_dir" "true" ||
            fixer_rc=$?
    fi
    if [[ $fixer_rc -ne 0 ]]; then
        record_agent_failure "$iteration" "phase_4" "Phase 4" "$fixer_agent" \
            "agent exited with code $fixer_rc" "$output_file"
        return 2
    fi

    [[ "$DRY_RUN" == "1" ]] && return 1

    local status
    if ! status="$(parse_status_block "$output_file" "SYNTHESIS_STATUS")"; then
        record_agent_failure "$iteration" "phase_4" "Phase 4" "$fixer_agent" \
            "missing or malformed SYNTHESIS_STATUS block" "$output_file"
        return 2
    fi
    local exit_signal=$(echo "$status" | jq -r '.exit_signal // false')
    local files_modified=$(echo "$status" | jq -r '.files_modified // 0')
    local in_scope_fixed
    in_scope_fixed="$(echo "$status" | jq -r '.in_scope_fixed // 0')"
    local pre_existing_fixed
    pre_existing_fixed="$(echo "$status" | jq -r '.pre_existing_fixed // 0')"
    local pre_existing_flagged
    pre_existing_flagged="$(echo "$status" | jq -r '.pre_existing_flagged // 0')"

    add_to_history "$iteration" "phase_4" "$fixer_agent" "$status"
    update_tracking "in_scope_fixed" "$in_scope_fixed"
    update_tracking "pre_existing_fixed" "$pre_existing_fixed"
    update_tracking "pre_existing_flagged" "$pre_existing_flagged"

    local synthesis_summary=$(echo "$status" | jq -r '.summary // "(no summary)"')
    log_info "Synthesis ($fixer_agent): $synthesis_summary"
    log_info "Synthesis scope counts: $in_scope_fixed in-scope fixed, $pre_existing_fixed pre-existing fixed, $pre_existing_flagged pre-existing flagged"

    # Record for circuit breaker
    local agents_agree=0
    # Check if both agents found similar issues
    local claude_meta=$(parse_status_block "$ARTIFACTS_DIR/iter${iteration}_3_claude_meta.md" "META_REVIEW_STATUS" 2>/dev/null || echo '{}')
    local consensus=$(echo "$claude_meta" | jq -r '.consensus_reached // "NO"')
    [[ "$consensus" == "YES" || "$consensus" == "true" ]] && agents_agree=1

    local issues_hash=$(cat "$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md" "$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md" | shasum -a 256 | cut -d' ' -f1)

    record_iteration_result "$iteration" "$files_modified" "$agents_agree" "$issues_hash"

    if [[ "$exit_signal" == "true" ]]; then
        log_success "Synthesis complete - no more issues"
        return 0
    fi

    log_info "Fixes applied, will verify in next iteration"
    return 1
}

# ============================================================================
# Main Review Loop
# ============================================================================
run_review_loop() {
    local target_dir="$1"
    target_dir="$(cd "$target_dir" && pwd)"

    log_info "Starting Adversarial Review Loop"
    log_info "Target: $target_dir"
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
    update_tracking "base_ref" "${BASE_REF:-whole-directory}"
    update_tracking "include_pre_existing" "$([[ "$INCLUDE_PRE_EXISTING" == "1" ]] && echo true || echo false)"
    update_tracking "status" "in_progress"
    update_tracking "started_at" "$(get_iso_timestamp)"

    local iteration=0
    log_verbose "Starting main loop (MAX_ITERATIONS=$MAX_ITERATIONS)..."

    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        ((iteration++)) || true
        log_info "=== Entering iteration $iteration ==="
        update_tracking "iteration" "$iteration"

        # Check circuit breaker
        if ! can_execute; then
            log_error "Circuit breaker is OPEN - halting"
            show_circuit_status
            update_tracking "status" "circuit_open"
            return 1
        fi

        echo ""
        log_info "=========================================="
        log_info "ITERATION $iteration / $MAX_ITERATIONS"
        log_info "=========================================="
        echo ""

        # Phase 1
        local phase_1_result=0
        run_phase_1 "$target_dir" "$iteration" || phase_1_result=$?
        if [[ $phase_1_result -eq 0 ]]; then
            log_success "Review complete - both agents report clean code"
            update_tracking "status" "clean"
            return 0
        elif [[ $phase_1_result -ne 1 ]]; then
            return 1
        fi
        echo ""

        # Phase 2
        if ! run_phase_2 "$target_dir" "$iteration"; then
            return 1
        fi
        echo ""

        # Phase 3
        if ! run_phase_3 "$target_dir" "$iteration"; then
            return 1
        fi
        echo ""

        # Phase 4
        if run_phase_4 "$target_dir" "$iteration"; then
            log_success "Synthesis complete"
            update_tracking "status" "clean"
            return 0
        fi
        echo ""

        log_info "Iteration $iteration complete, will verify fixes..."
        sleep 2
    done

    log_warning "Reached max iterations ($MAX_ITERATIONS)"
    update_tracking "status" "max_iterations"
    return 1
}

# ============================================================================
# Status & Management Commands
# ============================================================================
show_status() {
    echo ""
    log_info "=== Adversarial Review Status ==="
    log_info "State dir: $AR_DIR"
    echo ""

    if [[ ! -f "$TRACKING_FILE" ]]; then
        echo "No tracking file found for this target. Run a review against it first."
        return
    fi

    jq -r '
        "Target:     \(.target_dir // "none")",
        "Scope:      \(.base_ref // "whole-directory")",
        "Pre-existing fixes: \(if .include_pre_existing then "included" else "report only" end)",
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
    ./adversarial_review.sh [OPTIONS] <target_directory>

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
    -b, --base REF          Review only files differing from this git ref,
                            including uncommitted and untracked source files
    --include-pre-existing  Allow Phase 4 to fix PRE_EXISTING findings too
                            (default: report them without applying changes)
    --status [DIR]          Show current status (scoped to DIR if given)
    --reset [DIR]           Reset all state (scoped to DIR if given)
    --reset-circuit [DIR]   Reset circuit breaker only (scoped to DIR if given)
    --circuit-status [DIR]  Show circuit breaker status (scoped to DIR if given)
    --dry-run               Show what would happen without executing

STATE:
    All state (tracking.json, circuit breaker, artifacts/) is scoped per
    target directory under state/<slug>/, so reviewing one project can't
    pollute or trip a circuit breaker for another. Pass the same target
    directory to --status/--reset/etc. to scope to that project.

PHASES:
    1. Independent Review   Claude and Codex review code in parallel
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
    ./adversarial_review.sh ../my-project
    ./adversarial_review.sh --base main ../my-project
    ./adversarial_review.sh -m 5 -v ../my-project
    ./adversarial_review.sh --dry-run ../my-project
    ./adversarial_review.sh --status

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
    local target_dir=""
    local custom_prompt=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -m|--max-iters)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -p|--prompt)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $1"
                    exit 1
                fi
                custom_prompt="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -t|--timeout)
                TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            -f|--fixer)
                FIXER="$2"
                shift 2
                ;;
            -b|--base)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $1"
                    exit 1
                fi
                BASE_REF="$2"
                shift 2
                ;;
            --include-pre-existing)
                INCLUDE_PRE_EXISTING=1
                shift
                ;;
            --status)
                show_status
                exit 0
                ;;
            --reset)
                reset_all
                exit 0
                ;;
            --reset-circuit)
                init_circuit_breaker
                reset_circuit_breaker "Manual reset"
                exit 0
                ;;
            --circuit-status)
                init_circuit_breaker
                show_circuit_status
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                target_dir="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target_dir" ]]; then
        log_error "No target directory specified"
        echo ""
        show_help
        exit 1
    fi

    if [[ ! -d "$target_dir" ]]; then
        log_error "Directory does not exist: $target_dir"
        exit 1
    fi

    if [[ -n "$BASE_REF" ]]; then
        if [[ "$(git -C "$target_dir" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
            log_error "Cannot use --base: target is not a git working tree: $target_dir"
            exit 1
        fi

        if ! BASE_COMMIT="$(git -C "$target_dir" rev-parse --verify --quiet --end-of-options "${BASE_REF}^{commit}")"; then
            log_error "Base ref '$BASE_REF' does not resolve to a commit in target: $target_dir"
            exit 1
        fi

        local scoped_files
        scoped_files="$(collect_file_list "$target_dir" "$BASE_COMMIT")"
        if [[ -z "$scoped_files" ]]; then
            log_error "No reviewable files differ from base '$BASE_REF'"
            exit 1
        fi
    fi

    if [[ -n "$custom_prompt" ]]; then
        if [[ ! -f "$custom_prompt" ]]; then
            log_error "Custom prompt is not a regular file: $custom_prompt"
            exit 1
        fi
        if [[ ! -r "$custom_prompt" ]]; then
            log_error "Custom prompt is not readable: $custom_prompt"
            exit 1
        fi
        if ! CUSTOM_REVIEW_CRITERIA="$(< "$custom_prompt")"; then
            log_error "Could not read custom prompt: $custom_prompt"
            exit 1
        fi
        log_info "Using additional review criteria: $custom_prompt"
    fi

    check_dependencies

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
        exit 1
    fi

    log_info "Phase 4 fixes will be implemented by: $FIXER"

    run_review_loop "$target_dir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
