## Issue Ledger

| ID | Resolved scope | Disposition | Resolution |
|---|---|---|---|
| CLAUDE-1 | IN_SCOPE | FIX | `Math.min` now determines `accepted` |
| CLAUDE-2 | IN_SCOPE | FIX | `rejected` now uses `requested - accepted` |
| CLAUDE-3 | IN_SCOPE | FIX | Added finite, non-negative integer validation |
| CODEX-1 | IN_SCOPE | FIX | Renamed helper to `assertNonNegativeInteger` |
| CODEX-2 | IN_SCOPE | FIX | Same implementation as CLAUDE-3 |
| CODEX-3 | IN_SCOPE | FIX | Same implementation as CLAUDE-1 |
| CODEX-4 | IN_SCOPE | FIX | Same implementation as CLAUDE-2 |
| CLAUDE-ADD-1 | IN_SCOPE | FIX | Added behavioral and invalid-input regression tests |

`CLAUDE-ADD-1` is `IN_SCOPE`: [REVIEW_BRIEF.md](/tmp/adversarial-review-fix.EA6yn1/REVIEW_BRIEF.md:3) defines `benchmark-base` as the review boundary, and `fa59c7e` introduced the weak test after that boundary.

### Fix #1: src/allocation.js

**Issue**: `accepted` used the larger value.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Both agents (`CLAUDE-1`, `CODEX-3`)  
**Change**: [allocation.js](/tmp/adversarial-review-fix.EA6yn1/src/allocation.js:11) now uses `Math.min(requested, capacity)`.

### Fix #2: src/allocation.js

**Issue**: `rejected` could become negative.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Both agents (`CLAUDE-2`, `CODEX-4`)  
**Change**: Computes the unallocated remainder as `requested - accepted`.

### Fix #3: src/allocation.js

**Issue**: Invalid arguments were accepted.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Both agents (`CLAUDE-3`, `CODEX-2`)  
**Change**: Validates both arguments as finite, non-negative integers and throws `TypeError` otherwise.

### Fix #4: src/allocation.js

**Issue**: `assertValid` did not describe the enforced constraint.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Codex  
**Change**: Renamed it to `assertNonNegativeInteger`.

### Fix #5: test/allocation.test.js

**Issue**: Tests only checked result keys and could not detect behavioral regressions.  
**Scope**: IN_SCOPE  
**Confidence**: MEDIUM  
**Source**: Claude (`CLAUDE-ADD-1`)  
**Change**: [allocation.test.js](/tmp/adversarial-review-fix.EA6yn1/test/allocation.test.js:6) now covers both allocation directions, zero/equal values, exact results, and invalid values for both arguments.

## Pre-existing issues noticed, not fixed

None.

## Validation

- `npm test`: 5/5 passed
- `git diff --check`: passed
- Modified files: 2

---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 4
MEDIUM_CONFIDENCE_FIXES: 1
ISSUES_SKIPPED: 0
IN_SCOPE_FIXED: 5
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 0
TESTS_RUN: YES
TESTS_PASSING: YES
FILES_MODIFIED: 2
EXIT_SIGNAL: true
SUMMARY: Fixed all 5 distinct in-scope findings; all tests and diff validation pass
---END_SYNTHESIS_STATUS---