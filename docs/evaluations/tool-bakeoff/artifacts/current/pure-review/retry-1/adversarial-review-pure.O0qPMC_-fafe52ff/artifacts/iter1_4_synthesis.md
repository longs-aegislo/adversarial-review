## Issue Ledger

| ID | Resolved scope | Disposition | Rationale |
|---|---|---|---|
| CLAUDE-1 | IN_SCOPE | FIX | Same open-redirect regression as CODEX-1 |
| CODEX-1 | IN_SCOPE | FIX | Restored protocol-relative URL rejection |
| CLAUDE-2 | IN_SCOPE | FIX | Same retry-delay regression as CODEX-2 |
| CODEX-2 | IN_SCOPE | FIX | Restored one-based exponential delay |
| CLAUDE-3 | IN_SCOPE | FIX | Same slicing regression as CODEX-3 |
| CODEX-3 | IN_SCOPE | FIX | Removed the erroneous `count - 1` |
| CLAUDE-ADD-1 | PRE_EXISTING | FLAG | Valid test gap, but scope policy prohibits modifying it |

The six `IN_SCOPE` IDs represent three unique fixes.

### Fix #1: src/helpers.js

**Issue**: `isSafeRedirect` accepted protocol-relative external URLs such as `//example.com`.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Both agents  
**Change**: Added an explicit `!target.startsWith("//")` guard in [src/helpers.js](/tmp/adversarial-review-pure.O0qPMC/src/helpers.js:1).

### Fix #2: src/helpers.js

**Issue**: `retryDelay` treated attempts as zero-based, doubling every required delay.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Both agents  
**Change**: Changed the exponent to `attempt - 1` in [src/helpers.js](/tmp/adversarial-review-pure.O0qPMC/src/helpers.js:9).

### Fix #3: src/helpers.js

**Issue**: `take` returned one fewer item and mishandled `count=0`.  
**Scope**: IN_SCOPE  
**Confidence**: HIGH  
**Source**: Both agents  
**Change**: Restored `items.slice(0, count)` in [src/helpers.js](/tmp/adversarial-review-pure.O0qPMC/src/helpers.js:13).

## Pre-existing issues noticed, not fixed

### CLAUDE-ADD-1

- **File/line**: [test/helpers.test.js](/tmp/adversarial-review-pure.O0qPMC/test/helpers.test.js:6)
- **Severity**: Low
- **Issue**: Existing tests do not assert the three important boundary behaviors.
- **Suggested fix**: Add assertions for `//evil.com`, first-attempt delay, exact-count slicing, and `count=0`.
- **Disposition**: FLAG — not modified because it is `PRE_EXISTING`.

## Verification

- `npm test`: passed, 1/1 test.
- Targeted runtime assertions for all corrected boundary cases: passed.
- `git diff --check`: passed.
- Modified files: only `src/helpers.js`.

---SYNTHESIS_STATUS---
HIGH_CONFIDENCE_FIXES: 3
MEDIUM_CONFIDENCE_FIXES: 0
ISSUES_SKIPPED: 0
IN_SCOPE_FIXED: 3
PRE_EXISTING_FIXED: 0
PRE_EXISTING_FLAGGED: 1
TESTS_RUN: YES
TESTS_PASSING: YES
FILES_MODIFIED: 1
EXIT_SIGNAL: true
SUMMARY: Fixed all 3 in-scope regressions; flagged the pre-existing test gap without modifying it; all checks pass
---END_SYNTHESIS_STATUS---