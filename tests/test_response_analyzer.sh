#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AR_DIR="$TEST_ROOT/state"

# shellcheck source=../lib/response_analyzer.sh
source "$SCRIPT_DIR/lib/response_analyzer.sh"

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
expected: $expected
actual:   $actual"
}

pass() {
    tests_run=$((tests_run + 1))
    echo "ok $tests_run - $1"
}

test_mixed_issue_scopes_are_structured_by_issue_id() {
    local fixture="$TEST_ROOT/mixed.md"
    cat > "$fixture" <<'EOF'
---REVIEW_STATUS---
ISSUES_FOUND: 2
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING
EXIT_SIGNAL: false
SUMMARY: Found one current and one historical issue
---END_REVIEW_STATUS---
EOF

    local actual
    actual="$(parse_status_block "$fixture" REVIEW_STATUS)"

    assert_eq "IN_SCOPE" "$(jq -r '.issue_scopes["CLAUDE-1"]' <<< "$actual")" \
        "the parser should retain an in-scope finding by ID"
    assert_eq "PRE_EXISTING" "$(jq -r '.issue_scopes["CLAUDE-2"]' <<< "$actual")" \
        "the parser should retain a pre-existing finding by ID"
    assert_eq "0" "$(jq -r '.scope_errors | length' <<< "$actual")" \
        "valid scope entries should not produce parser errors"
    pass "mixed issue scopes are structured by issue ID"
}

test_malformed_and_missing_scope_tags_are_visible() {
    local malformed="$TEST_ROOT/malformed.md"
    cat > "$malformed" <<'EOF'
---REVIEW_STATUS---
ISSUES_FOUND: 3
ISSUE_SCOPES: CODEX-1=IN_SCOPE, CODEX-2=UNKNOWN, BROKEN
EXIT_SIGNAL: false
SUMMARY: Includes malformed scope data
---END_REVIEW_STATUS---
EOF

    local malformed_result
    malformed_result="$(parse_status_block "$malformed" REVIEW_STATUS)"

    assert_eq '{"CODEX-1":"IN_SCOPE"}' "$(jq -c '.issue_scopes' <<< "$malformed_result")" \
        "invalid scope entries should not contaminate the structured scope map"
    assert_eq '["CODEX-2=UNKNOWN","BROKEN","expected 3 ISSUE_SCOPES entries, found 1"]' \
        "$(jq -c '.scope_errors' <<< "$malformed_result")" \
        "malformed scope entries should remain visible to callers"

    local missing="$TEST_ROOT/missing.md"
    cat > "$missing" <<'EOF'
---REVIEW_STATUS---
ISSUES_FOUND: 1
EXIT_SIGNAL: false
SUMMARY: Scope field was omitted
---END_REVIEW_STATUS---
EOF

    local missing_result
    missing_result="$(parse_status_block "$missing" REVIEW_STATUS)"

    assert_eq '{}' "$(jq -c '.issue_scopes' <<< "$missing_result")" \
        "a missing scope field should produce an empty scope map"
    assert_eq '["missing ISSUE_SCOPES"]' "$(jq -c '.scope_errors' <<< "$missing_result")" \
        "a missing scope field for reported issues should be explicit"

    local partial="$TEST_ROOT/partial.md"
    cat > "$partial" <<'EOF'
---REVIEW_STATUS---
ISSUES_FOUND: 2
ISSUE_SCOPES: CODEX-1=IN_SCOPE
EXIT_SIGNAL: false
SUMMARY: One issue is missing a scope tag
---END_REVIEW_STATUS---
EOF

    local partial_result
    partial_result="$(parse_status_block "$partial" REVIEW_STATUS)"

    assert_eq '["expected 2 ISSUE_SCOPES entries, found 1"]' \
        "$(jq -c '.scope_errors' <<< "$partial_result")" \
        "a partially missing per-issue scope tag should be explicit"

    local none_with_findings="$TEST_ROOT/none-with-findings.md"
    cat > "$none_with_findings" <<'EOF'
---REVIEW_STATUS---
ISSUES_FOUND: 1
ISSUE_SCOPES: NONE
EXIT_SIGNAL: false
SUMMARY: Invalid NONE marker
---END_REVIEW_STATUS---
EOF

    local none_result
    none_result="$(parse_status_block "$none_with_findings" REVIEW_STATUS)"

    assert_eq '["expected 1 ISSUE_SCOPES entries, found 0"]' \
        "$(jq -c '.scope_errors' <<< "$none_result")" \
        "NONE should be rejected when findings were reported"
    pass "malformed and missing scope tags are visible"
}

test_meta_review_can_represent_resolved_scope_disagreements() {
    local fixture="$TEST_ROOT/meta.md"
    cat > "$fixture" <<'EOF'
---META_REVIEW_STATUS---
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 1
ISSUE_SCOPES: CLAUDE-1=PRE_EXISTING, CODEX-ADD-1=IN_SCOPE
SUMMARY: Resolved both validity and scope
---END_META_REVIEW_STATUS---
EOF

    local actual
    actual="$(parse_status_block "$fixture" META_REVIEW_STATUS)"

    assert_eq '{"CLAUDE-1":"PRE_EXISTING","CODEX-ADD-1":"IN_SCOPE"}' \
        "$(jq -c '.issue_scopes' <<< "$actual")" \
        "meta-review output should preserve the resolved scope for every issue"
    assert_eq "1" "$(jq -r '.scope_disagreements' <<< "$actual")" \
        "meta-review output should expose how many scope disagreements were reconciled"
    pass "meta-review can represent resolved scope disagreements"
}

test_synthesis_scope_counts_are_machine_readable() {
    local fixture="$TEST_ROOT/synthesis.md"
    cat > "$fixture" <<'EOF'
---SYNTHESIS_STATUS---
IN_SCOPE_FIXED: 3
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 2
EXIT_SIGNAL: true
SUMMARY: Applied current fixes and reported historical findings
---END_SYNTHESIS_STATUS---
EOF

    local actual
    actual="$(parse_status_block "$fixture" SYNTHESIS_STATUS)"

    assert_eq "3" "$(jq -r '.in_scope_fixed' <<< "$actual")" \
        "in-scope fix counts should remain numeric"
    assert_eq "0" "$(jq -r '.pre_existing_fixed' <<< "$actual")" \
        "pre-existing fix counts should remain numeric"
    assert_eq "2" "$(jq -r '.pre_existing_flagged' <<< "$actual")" \
        "flagged pre-existing counts should remain numeric"
    pass "synthesis scope counts are machine readable"
}

test_mixed_issue_scopes_are_structured_by_issue_id
test_malformed_and_missing_scope_tags_are_visible
test_meta_review_can_represent_resolved_scope_disagreements
test_synthesis_scope_counts_are_machine_readable

echo "1..$tests_run"
