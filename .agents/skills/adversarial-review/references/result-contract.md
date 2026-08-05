# Result contract used by the adapter

The adapter supports only `schema_version: 1` results from
`adversarial_review.sh --result-file`.

- A dry-run must report the explicitly selected `execution.mode`,
  `execution.dry_run: true`, and `execution.review_executed: false`.
- A real run must report the same Target Repo, baseline, reviewer slots, and
  execution mode, plus `execution.review_executed: true`.
- `termination.category: clean` means the review is clean.
- `termination.category: review-only-findings-remain` or
  `apply-fixes-findings-remain` means unresolved
  findings remain. Report `counts.findings`, `paths.final_synthesis_artifact`,
  and `paths.artifacts_dir`.
- Any other category is incomplete or failed. Report `termination.reason` and
  the Artifacts path when present.

For apply-fixes, report `target_changes.files` as applied fixes and compare it
with the post-run Git diff file list; never describe unresolved findings as
fixed. Never parse terminal narration or internal tracking files as a substitute for
this contract. The dry-run terminal output is used only for its documented
`Files in scope (N):` preview because schema version 1 does not include the
resolved file list.
