# Adversarial Code Review - Phase 2: Cross-Review

You are reviewing another AI agent's code review findings.
Your task is to validate, challenge, or expand upon their analysis.

You have read access to the actual project in the current working
directory - use your file-reading tools to open the files a finding
references and verify it against the real source instead of taking the
other agent's description on faith.

## Your Objectives

1. **Validate**: Which findings are correct and well-reasoned?
2. **Challenge**: Which findings are incorrect, false positives, or overstated?
3. **Expand**: What issues did they miss that you would have caught?
4. **Contextualize**: Are any issues more or less severe than stated?
5. **Classify scope**: Is each `IN_SCOPE` / `PRE_EXISTING` tag supported by
   the diff boundary or repository history?

## Analysis Guidelines

The other agent numbered their findings with their own agent tag (e.g.
`CLAUDE-1`, `CODEX-3`, ...). You MUST address every single one of their
IDs individually, using their exact ID string - do not summarize several
of them together in prose and do not silently skip any. Missing an ID
here means it will look unresolved to whoever synthesizes the final
fixes, even if you privately agree with it.

For EACH of their numbered findings:

### If you AGREE:
- State "{THEIR_ID}: VALID" and explain why
- Optionally suggest a better fix if you have one

### If you DISAGREE:
- State "{THEIR_ID}: INVALID" or "{THEIR_ID}: FALSE POSITIVE" and explain why
- Provide evidence (code context, documentation, etc.)

### If you have CONCERNS:
- State "{THEIR_ID}: UNCLEAR" or "{THEIR_ID}: NEEDS MORE CONTEXT"
- Explain what additional information is needed

For every verdict, also state whether you agree with the reported scope. If
you disagree, give your resolved scope and cite the changed-file boundary or
the relevant `git blame` / `git log` evidence. Scope disagreement is separate
from severity or validity disagreement and must not be silently folded into
either one.

## Verdict Ledger (REQUIRED, before the status block)

Immediately before the status block, list every one of their IDs (their
exact ID strings, e.g. `CODEX-1`) with your one-word verdict, so it can be
cross-checked mechanically:

```
VERDICTS: CODEX-1=VALID, CODEX-2=INVALID, CODEX-3=UNCLEAR, ...
SCOPE_VERDICTS: CODEX-1=IN_SCOPE, CODEX-2=PRE_EXISTING, CODEX-3=PRE_EXISTING, ...
```

The count of entries in VERDICTS MUST equal the number of findings the
other agent reported.

## Additional Findings

After reviewing their findings, add any issues YOU found that they missed.
Give each one an ID using your own agent tag with an `-ADD-` suffix (e.g.
`CLAUDE-ADD-1`, `CLAUDE-ADD-2`, ...) so the synthesis phase can track these
alongside the Phase 1 findings instead of them getting silently dropped.
Follow the same format as Phase 1:
- ID, File, Line, Severity, Scope, Issue, Fix

## Adversarial Perspective

Be critical but fair:
- Don't accept findings at face value - verify them
- Don't reject findings just to disagree - have reasons
- Consider if the other agent has context you're missing
- Consider if you have context they're missing

## Status Block (REQUIRED)

```
---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: <number they got right>
FINDINGS_CHALLENGED: <number you disagree with>
FINDINGS_ADDED: <number of new issues you found>
ISSUE_SCOPES: <ID>=IN_SCOPE | PRE_EXISTING, ... (or NONE)
AGREEMENT_LEVEL: FULL | PARTIAL | LOW
CONFIDENCE: HIGH | MEDIUM | LOW
SUMMARY: <one line assessment>
---END_CROSS_REVIEW_STATUS---
```

### Agreement Level Guide
- **FULL**: You agree with 80%+ of their findings
- **PARTIAL**: You agree with 40-80% of their findings
- **LOW**: You agree with less than 40% of their findings

### Example: High Agreement
```
---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 5
FINDINGS_CHALLENGED: 1
FINDINGS_ADDED: 2
ISSUE_SCOPES: CODEX-1=IN_SCOPE, CODEX-2=PRE_EXISTING, CLAUDE-ADD-1=IN_SCOPE, CLAUDE-ADD-2=PRE_EXISTING
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: Strong review, one false positive, added two edge cases
---END_CROSS_REVIEW_STATUS---
```

### Example: Significant Disagreement
```
---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 1
FINDINGS_CHALLENGED: 4
FINDINGS_ADDED: 3
ISSUE_SCOPES: CODEX-1=PRE_EXISTING, CLAUDE-ADD-1=IN_SCOPE, CLAUDE-ADD-2=PRE_EXISTING, CLAUDE-ADD-3=IN_SCOPE
AGREEMENT_LEVEL: LOW
CONFIDENCE: MEDIUM
SUMMARY: Many false positives, missed critical security issues
---END_CROSS_REVIEW_STATUS---
```
