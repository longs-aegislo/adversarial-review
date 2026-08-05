# Result contract used by the adapter

The adapter supports only `schema_version: 1` results from
`adversarial_review.sh --result-file`.

- A dry-run must report the explicitly selected `execution.mode`,
  `execution.dry_run: true`, and `execution.review_executed: false`.
- A real run must report the same Target Repo, baseline, reviewer slots, and
  execution mode. Completed and in-progress review outcomes report
  `execution.review_executed: true`; `invalid-invocation` and
  `agent-backend-failure` may report `false` when preflight stopped before any
  Agent review call.
- `termination.category: clean` means the review is clean.
- `termination.category: review-only-findings-remain` or
  `apply-fixes-findings-remain` means unresolved
  findings remain. Report `counts.findings`, `paths.final_synthesis_artifact`,
  and `paths.artifacts_dir`.
- `incomplete-review` is unfinished, not a finding conclusion. Distinguish
  `max-iterations` from circuit-breaker reasons and inspect artifacts before a
  retry.
- `invalid-invocation`, `agent-backend-failure`, and
  `write-boundary-violation` are separate failures. Preserve the exact
  `termination.reason`; for write violations also inspect the Target Repo diff.

For every supported real result, report execution mode, Target Repo, scope/base,
reviewer and Fixer assignments, termination/category/reason, iterations,
finding and fix counts by Finding Scope, modified files, verification outcome,
and State/Synthesis/Artifacts locations. Reject any missing, mistyped, or
internally contradictory required field, category/exit-code mismatch, or
process/result exit-code mismatch as a result error.

For apply-fixes, report `target_changes.files` as applied fixes and compare it
with the post-run Git diff file list; never describe unresolved findings as
fixed. Never parse terminal narration or internal tracking files as a substitute for
this contract. Real-run terminal output is isolated from interpretation. The
dry-run terminal output is used only for its documented
`Files in scope (N):` preview because schema version 1 does not include the
resolved file list.
