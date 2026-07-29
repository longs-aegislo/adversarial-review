# Adversarial Code Review - Phase 3: Meta-Review

You are reviewing feedback that another AI agent provided about YOUR original review.
This is your opportunity to defend, concede, or refine your positions.

You have read access to the actual project in the current working
directory - re-check the actual source before defending or conceding a
point, rather than relying only on the text descriptions below.

## Your Objectives

1. **Reflect**: Consider the other agent's critique of your work
2. **Defend**: Maintain positions where you're confident you're correct
3. **Concede**: Acknowledge where they raised valid points
4. **Synthesize**: Help reach consensus on the final set of issues
5. **Resolve scope**: Reconcile every disagreement about `IN_SCOPE` versus
   `PRE_EXISTING`, independently of severity and validity

## For Each Challenged Finding

When the other agent disagreed with your finding:

### If their challenge is VALID:
- State "CONCEDE"
- Explain why they're right
- Withdraw or downgrade the finding

### If their challenge is INVALID:
- State "MAINTAIN"
- Provide additional evidence/reasoning
- Explain why your original finding stands

### If more information needed:
- State "CLARIFY"
- Provide the additional context
- Revise severity if appropriate

## For New Issues They Found

Evaluate issues the other agent added during cross-review (their
`{TAG}-ADD-N` IDs) using their exact ID string so synthesis can track them:
- "{THEIR_ADD_ID}: VALID-NEW": They found something real I missed
- "{THEIR_ADD_ID}: INVALID-NEW": Their new finding is incorrect
- "{THEIR_ADD_ID}: DUPLICATE": Already covered in my original review

## Reaching Consensus

Consider the meta-question: If you and the other agent were in the same room, what would you agree on?

Produce a **CONSENSUS LIST** of issues you believe should be fixed:
- Include validated findings from both reviews
- Exclude false positives from either side
- Note any remaining disagreements

For every issue ID, record one resolved scope tag. Compare both agents'
classification and evidence. If the affected code predates the reviewed
change, or the evidence remains ambiguous, resolve it as `PRE_EXISTING` with
a short note. Do not invent a third scope tier.

## Scope Reconciliation Ledger (REQUIRED)

Before the status block, make every scope disagreement visible. For each issue
whose Phase 1 scope differs from the Phase 2 scope verdict, write:

```
SCOPE_RECONCILIATION: <ID> <PHASE_1_SCOPE> vs <PHASE_2_SCOPE> -> <RESOLVED_SCOPE> — <one-line reason>
```

If there were no scope disagreements, write `SCOPE_RECONCILIATION: NONE`.
`SCOPE_DISAGREEMENTS` in the status block must equal the number of
reconciliation entries.

## Status Block (REQUIRED)

```
---META_REVIEW_STATUS---
POSITIONS_DEFENDED: <number of your findings you maintain>
POSITIONS_CONCEDED: <number of your findings you withdraw>
NEW_ISSUES_ACCEPTED: <number of their new findings you accept>
NEW_ISSUES_REJECTED: <number of their new findings you reject>
REMAINING_DISAGREEMENTS: <number of issues still disputed>
CONSENSUS_REACHED: YES | PARTIAL | NO
SCOPE_DISAGREEMENTS: <number reconciled above>
ISSUE_SCOPES: <ID>=IN_SCOPE | PRE_EXISTING, ... (or NONE)
SUMMARY: <one line summary of where things stand>
---END_META_REVIEW_STATUS---
```

### Example: Reached Consensus
```
---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 4
POSITIONS_CONCEDED: 1
NEW_ISSUES_ACCEPTED: 2
NEW_ISSUES_REJECTED: 0
REMAINING_DISAGREEMENTS: 0
CONSENSUS_REACHED: YES
SCOPE_DISAGREEMENTS: 1
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CODEX-1=PRE_EXISTING, CODEX-ADD-1=IN_SCOPE
SUMMARY: Agreed on 6 issues, withdrew 1 false positive
---END_META_REVIEW_STATUS---
```

### Example: Persistent Disagreement
```
---META_REVIEW_STATUS---
POSITIONS_DEFENDED: 3
POSITIONS_CONCEDED: 0
NEW_ISSUES_ACCEPTED: 1
NEW_ISSUES_REJECTED: 2
REMAINING_DISAGREEMENTS: 2
CONSENSUS_REACHED: PARTIAL
SCOPE_DISAGREEMENTS: 1
ISSUE_SCOPES: CLAUDE-1=PRE_EXISTING, CODEX-1=IN_SCOPE
SUMMARY: Agree on 4 issues, dispute severity of 2 others
---END_META_REVIEW_STATUS---
```

## Final Consensus List

At the end of your response, provide a clear list:

```
---CONSENSUS_ISSUES---
1. [AGREED] [IN_SCOPE] CLAUDE-1 file.py:123 - Description (SEVERITY)
2. [AGREED] [PRE_EXISTING] CODEX-1 file.py:456 - Description (SEVERITY)
3. [DISPUTED] [PRE_EXISTING] CODEX-2 file.py:789 - Description (Your view vs Their view)
---END_CONSENSUS_ISSUES---
```
