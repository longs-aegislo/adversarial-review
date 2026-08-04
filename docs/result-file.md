# Machine-readable result file

Pass `--result-file <path>` to make each invocation atomically replace that
path with one complete JSON object. The destination becomes active only after
argument parsing reaches the option. Once active, normal completion and every
later failure path produce a result. The existing terminal output is unchanged.

```bash
./adversarial_review.sh --apply-fixes --result-file review-result.json \
  claude codex ../my-project
```

The writer creates a temporary file beside the destination and renames it only
after the complete object has been written. Readers therefore see either the
previous complete result or the new complete result, never a partial document.

## Schema version 1

The top-level object contains:

- `schema_version`: currently `1`.
- `target_repo`: target identity, absolute path, Git root, `origin` URL, and
  starting `HEAD` commit when available.
- `reviewers`: resolved `slot_a` and `slot_b` backend assignments.
- `synthesis`: requested fixer and the Agent that actually executed Phase 4;
  `executed_by` is `null` when Phase 4 did not run.
- `scope`: `whole-directory` or `base`, plus the requested base ref and its
  resolved commit.
- `execution`: `review-only`/`apply-fixes`, `dry_run`, whether any review Agent
  actually executed, and the pre-existing-finding policy.
- `termination`: the stable exit-status category, a more specific reason, and
  numeric process exit code. Categories match the
  [exit-status contract](exit-statuses.md).
- `iterations`: iterations entered by this invocation.
- `counts`: unique `IN_SCOPE`/`PRE_EXISTING` findings from parsed status ledgers,
  plus fixes and flagged pre-existing findings from parsed Synthesis status.
- `target_changes`: whether the invocation changed the target and the changed,
  created, or deleted relative file paths.
- `paths`: state directory, Artifact directory, and final Synthesis Artifact
  when one exists.

`--dry-run` retains the selected execution mode but sets `dry_run` to `true`,
`review_executed` to `false`, and `synthesis.executed_by` to `null`. Its normal
max-iteration result remains `incomplete-review`; it cannot be mistaken for a
completed real review.

Values come from the same parsed status blocks, tracking state, resolved CLI
configuration, and target snapshots used by the human-facing workflow. The
result writer does not parse terminal text.
