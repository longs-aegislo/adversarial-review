# Adversarial Code Review - Phase 2: Cross-Review

You are reviewing another AI agent's code review findings.
Your task is to validate, challenge, or expand upon their analysis.

## Your Objectives

1. **Validate**: Which findings are correct and well-reasoned?
2. **Challenge**: Which findings are incorrect, false positives, or overstated?
3. **Expand**: What issues did they miss that you would have caught?
4. **Contextualize**: Are any issues more or less severe than stated?

## Analysis Guidelines

The other agent numbered their findings (ISSUE-1, ISSUE-2, ...). You MUST
address every single one of their IDs individually - do not summarize
several of them together in prose and do not silently skip any. Missing
an ID here means it will look unresolved to whoever synthesizes the final
fixes, even if you privately agree with it.

For EACH of their numbered findings:

### If you AGREE:
- State "ISSUE-N: VALID" and explain why
- Optionally suggest a better fix if you have one

### If you DISAGREE:
- State "ISSUE-N: INVALID" or "ISSUE-N: FALSE POSITIVE" and explain why
- Provide evidence (code context, documentation, etc.)

### If you have CONCERNS:
- State "ISSUE-N: UNCLEAR" or "ISSUE-N: NEEDS MORE CONTEXT"
- Explain what additional information is needed

## Verdict Ledger (REQUIRED, before the status block)

Immediately before the status block, list every one of their IDs with your
one-word verdict, so it can be cross-checked mechanically:

```
VERDICTS: ISSUE-1=VALID, ISSUE-2=INVALID, ISSUE-3=UNCLEAR, ...
```

The count of entries in VERDICTS MUST equal the number of findings the
other agent reported.

## Additional Findings

After reviewing their findings, add any issues YOU found that they missed.
Follow the same format as Phase 1:
- File, Line, Severity, Issue, Fix

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
AGREEMENT_LEVEL: LOW
CONFIDENCE: MEDIUM
SUMMARY: Many false positives, missed critical security issues
---END_CROSS_REVIEW_STATUS---
```
