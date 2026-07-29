#!/bin/bash
# Response Analyzer for Adversarial Review
# Analyzes agent outputs to detect completion, agreement, and issues

# Source date utilities
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/date_utils.sh"

# Configuration
AR_DIR="${AR_DIR:-.}"
ANALYSIS_FILE="$AR_DIR/.response_analysis.json"

# Patterns
COMPLETION_PATTERNS=("NO_ISSUES" "no issues" "code is clean" "all tests pass" "no problems found")
FIX_PATTERNS=("fixed" "changed" "modified" "updated" "corrected" "refactored" "FIXES_MADE")
DISAGREEMENT_PATTERNS=("disagree" "incorrect" "wrong" "invalid" "false positive" "not an issue")
AGREEMENT_PATTERNS=("agree" "valid point" "correct" "good catch" "confirmed")

# Parse the last complete structured status block from an agent response.
# ISSUE_SCOPES is promoted from a comma-separated status field into a JSON
# object keyed by issue ID. Invalid entries are preserved in scope_errors so
# callers never have to infer whether a missing classification was accidental.
parse_status_block() {
    local file="$1"
    local block_name="${2:-REVIEW_STATUS}"

    if [[ ! -f "$file" ]]; then
        echo '{"error":"file not found","issue_scopes":{},"scope_errors":[]}'
        return 1
    fi

    local content
    content="$(cat "$file")"
    local block
    block="$(echo "$content" | awk -v start="---${block_name}---" -v end="---END_${block_name}---" '
        index($0, start) { capture=1; buf=""; next }
        index($0, end) { capture=0; last=buf }
        capture { buf = buf $0 "\n" }
        END { printf "%s", last }
    ')"

    if [[ -z "$block" ]]; then
        if echo "$content" | grep -qE '^\s*NO_ISSUES\s*$'; then
            echo '{"exit_signal":true,"issues_found":0,"issue_scopes":{},"scope_errors":[]}'
            return 0
        fi
        echo '{"error":"no status block","issue_scopes":{},"scope_errors":[]}'
        return 1
    fi

    local json="{"
    local first=true
    local issue_scopes='{}'
    local scope_errors='[]'
    local issue_scopes_seen=false
    while IFS=: read -r key value; do
        [[ -z "$key" ]] && continue
        key="$(echo "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [[ "$key" == "issue_scopes" ]]; then
            issue_scopes_seen=true
            if [[ "$value" != "NONE" ]]; then
                local scope_entries=()
                local entry
                IFS=',' read -r -a scope_entries <<< "$value"
                for entry in "${scope_entries[@]}"; do
                    entry="$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                    if [[ "$entry" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)=(IN_SCOPE|PRE_EXISTING)$ ]]; then
                        issue_scopes="$(jq -c \
                            --arg id "${BASH_REMATCH[1]}" \
                            --arg scope "${BASH_REMATCH[2]}" \
                            '. + {($id): $scope}' <<< "$issue_scopes")"
                    else
                        scope_errors="$(jq -c --arg entry "$entry" '. + [$entry]' <<< "$scope_errors")"
                    fi
                done
            fi
            continue
        fi

        [[ "$first" == "true" ]] && first=false || json+=","

        if [[ "$value" =~ ^[0-9]+$ ]]; then
            json+="\"$key\": $value"
        elif [[ "$value" == "true" || "$value" == "false" ]]; then
            json+="\"$key\": $value"
        elif [[ "$value" == "YES" || "$value" == "FULL" ]]; then
            json+="\"$key\": true"
        elif [[ "$value" == "NO" || "$value" == "LOW" ]]; then
            json+="\"$key\": false"
        else
            json+="\"$key\": \"$value\""
        fi
    done <<< "$block"
    json+="}"

    local issues_found
    issues_found="$(jq -r '.issues_found // 0' <<< "$json")"
    if [[ "$issue_scopes_seen" == "false" ]] &&
        { [[ "$issues_found" -gt 0 ]] ||
          [[ "$block_name" == "CROSS_REVIEW_STATUS" ]] ||
          [[ "$block_name" == "META_REVIEW_STATUS" ]]; }; then
        scope_errors="$(jq -c '. + ["missing ISSUE_SCOPES"]' <<< "$scope_errors")"
    fi

    jq -c \
        --argjson issue_scopes "$issue_scopes" \
        --argjson scope_errors "$scope_errors" \
        '. + {issue_scopes: $issue_scopes, scope_errors: $scope_errors}' <<< "$json"
}

# Analyze a single agent's response
# Returns JSON with structured analysis
analyze_response() {
    local response_file=$1
    local agent_name=$2

    if [[ ! -f "$response_file" ]]; then
        echo '{"error": "file not found"}'
        return 1
    fi

    local content=$(cat "$response_file")
    local content_lower=$(echo "$content" | tr '[:upper:]' '[:lower:]')

    # Detect completion (no issues)
    local is_complete="false"
    for pattern in "${COMPLETION_PATTERNS[@]}"; do
        if echo "$content_lower" | grep -qiE "^\s*${pattern}\s*$|${pattern}"; then
            is_complete="true"
            break
        fi
    done

    # Explicit NO_ISSUES check (more strict)
    local explicit_no_issues="false"
    if echo "$content" | grep -qE '^\s*NO_ISSUES\s*$'; then
        explicit_no_issues="true"
        is_complete="true"
    fi

    # Detect fixes mentioned
    local mentions_fixes="false"
    local fix_count=0
    for pattern in "${FIX_PATTERNS[@]}"; do
        local matches=$(echo "$content_lower" | grep -oiE "$pattern" | wc -l | tr -d '[:space:]')
        fix_count=$((fix_count + matches))
    done
    [[ $fix_count -gt 0 ]] && mentions_fixes="true"

    # Detect disagreement indicators
    local disagreement_count=0
    for pattern in "${DISAGREEMENT_PATTERNS[@]}"; do
        local matches=$(echo "$content_lower" | grep -oiE "$pattern" | wc -l | tr -d '[:space:]')
        disagreement_count=$((disagreement_count + matches))
    done

    # Detect agreement indicators
    local agreement_count=0
    for pattern in "${AGREEMENT_PATTERNS[@]}"; do
        local matches=$(echo "$content_lower" | grep -oiE "$pattern" | wc -l | tr -d '[:space:]')
        agreement_count=$((agreement_count + matches))
    done

    # Count lines (as proxy for detail level)
    local line_count=$(echo "$content" | wc -l | tr -d '[:space:]')

    # Generate hash of issues (for detecting same issues across iterations)
    local issues_hash=$(echo "$content" | grep -iE "(issue|bug|problem|error|warning|should)" | sort | shasum -a 256 | cut -d' ' -f1)

    # Output JSON
    cat << EOF
{
    "agent": "$agent_name",
    "is_complete": $is_complete,
    "explicit_no_issues": $explicit_no_issues,
    "mentions_fixes": $mentions_fixes,
    "fix_count": $fix_count,
    "disagreement_count": $disagreement_count,
    "agreement_count": $agreement_count,
    "line_count": $line_count,
    "issues_hash": "$issues_hash",
    "analyzed_at": "$(get_iso_timestamp)"
}
EOF
}

# Compare two agents' responses to determine agreement level
# Returns: "full_agreement", "partial_agreement", "disagreement"
compare_responses() {
    local response1_file=$1
    local response2_file=$2

    local analysis1=$(analyze_response "$response1_file" "agent1")
    local analysis2=$(analyze_response "$response2_file" "agent2")

    local complete1=$(echo "$analysis1" | jq -r '.is_complete')
    local complete2=$(echo "$analysis2" | jq -r '.is_complete')
    local hash1=$(echo "$analysis1" | jq -r '.issues_hash')
    local hash2=$(echo "$analysis2" | jq -r '.issues_hash')

    # Both say no issues
    if [[ "$complete1" == "true" ]] && [[ "$complete2" == "true" ]]; then
        echo "full_agreement"
        return 0
    fi

    # Both found issues with similar hash
    if [[ "$complete1" == "false" ]] && [[ "$complete2" == "false" ]]; then
        if [[ "$hash1" == "$hash2" ]]; then
            echo "full_agreement"
        else
            echo "partial_agreement"
        fi
        return 0
    fi

    # One says clean, other says issues
    echo "disagreement"
    return 0
}

# Analyze cross-review to detect if agents convinced each other
analyze_cross_review() {
    local original_review=$1
    local cross_review=$2

    local cross_analysis=$(analyze_response "$cross_review" "cross_reviewer")

    local agreement=$(echo "$cross_analysis" | jq -r '.agreement_count')
    local disagreement=$(echo "$cross_analysis" | jq -r '.disagreement_count')

    if [[ $agreement -gt $disagreement ]]; then
        echo "convinced"
    elif [[ $disagreement -gt $agreement ]]; then
        echo "rejected"
    else
        echo "neutral"
    fi
}

# Store analysis results
store_analysis() {
    local iteration=$1
    local phase=$2
    local result=$3

    mkdir -p "$AR_DIR"

    local existing='[]'
    if [[ -f "$ANALYSIS_FILE" ]]; then
        existing=$(cat "$ANALYSIS_FILE")
    fi

    local entry=$(cat << EOF
{
    "iteration": $iteration,
    "phase": "$phase",
    "result": $result,
    "timestamp": "$(get_iso_timestamp)"
}
EOF
)

    echo "$existing" | jq ". += [$entry]" > "$ANALYSIS_FILE"
}

# Get summary of all analyses
get_analysis_summary() {
    if [[ ! -f "$ANALYSIS_FILE" ]]; then
        echo '{"total_iterations": 0, "analyses": []}'
        return
    fi

    cat "$ANALYSIS_FILE"
}

# Clear analysis history
clear_analysis() {
    rm -f "$ANALYSIS_FILE"
    echo '[]' > "$ANALYSIS_FILE"
}

# Export functions
export -f analyze_response
export -f parse_status_block
export -f compare_responses
export -f analyze_cross_review
export -f store_analysis
export -f get_analysis_summary
export -f clear_analysis
