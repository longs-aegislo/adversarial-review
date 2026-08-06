# Machine-readable result file

Pass `--result-file <path>` to make each invocation atomically replace that
path with one complete JSON object. The destination becomes active only after
argument parsing reaches the option. Once active, normal completion and every
later failure path produce a result. The existing terminal output is unchanged.

For Git worktrees, `target_changes.files` covers tracked and unignored
untracked files; Git-ignored files are excluded. URL userinfo is removed from
`target_repo.identity` and `target_repo.remote_url` so embedded credentials are
not persisted in the result artifact.

```bash
./adversarial_review.sh --apply-fixes --result-file review-result.json \
  claude codex ../my-project
```

The writer creates a temporary file beside the destination and renames it only
after the complete object has been written. Readers therefore see either the
previous complete result or the new complete result, never a partial document.

## Schema version 1

Every field in the public schema is listed below. A nullable string is JSON
`null` when the value is unavailable or the corresponding phase did not run.

- `schema_version` (integer): currently `1`.
- `target_repo` (object): `identity` (remote URL when available, otherwise the
  absolute target path), `path` (absolute target path), nullable `git_root`,
  nullable credential-scrubbed `remote_url`, and nullable starting
  `head_commit`.
- `reviewers` (object): nullable resolved `slot_a` and `slot_b` backends.
- `synthesis` (object): nullable `requested_fixer` and nullable `executed_by`;
  the latter is the Agent that actually ran Phase 4.
- `scope` (object): `kind` (`whole-directory` or `base`), nullable
  `requested_base_ref`, and nullable `resolved_base_commit`.
- `execution` (object): `mode` (`review-only` or `apply-fixes`), boolean
  `dry_run`, boolean `review_executed`, and boolean `include_pre_existing`.
- `termination` (object): stable `category`, more specific `reason`, and
  numeric `exit_code`. Categories match the
  [exit-status contract](exit-statuses.md).
- `iterations` (integer): iterations entered by this invocation.
- `counts.findings` (object): unique `in_scope` and `pre_existing` finding
  counts plus `scope_conflicts`. A scope disagreement is conservatively
  included in both `pre_existing` and `scope_conflicts`.
- `counts.fixes` (object): `in_scope` and `pre_existing` fix counts.
- `counts.pre_existing_flagged` (integer): pre-existing findings reported but
  not fixed by Synthesis.
- `target_changes` (object): boolean `modified` plus `files`, an array of
  changed, created, or deleted paths relative to the target.
- `paths` (object): `state_dir`, `artifacts_dir`, and nullable
  `final_synthesis_artifact` paths.

Example (paths, commit IDs, and counts are illustrative):

```json
{
  "schema_version": 1,
  "target_repo": {
    "identity": "https://github.com/example/shop.git",
    "path": "/work/shop",
    "git_root": "/work/shop",
    "remote_url": "https://github.com/example/shop.git",
    "head_commit": "0123456789abcdef0123456789abcdef01234567"
  },
  "reviewers": { "slot_a": "claude", "slot_b": "codex" },
  "synthesis": { "requested_fixer": "codex", "executed_by": "codex" },
  "scope": {
    "kind": "base",
    "requested_base_ref": "main",
    "resolved_base_commit": "fedcba9876543210fedcba9876543210fedcba98"
  },
  "execution": {
    "mode": "review-only",
    "dry_run": false,
    "review_executed": true,
    "include_pre_existing": false
  },
  "termination": {
    "category": "review-only-findings-remain",
    "reason": "review-only-findings-remain",
    "exit_code": 10
  },
  "iterations": 1,
  "counts": {
    "findings": { "in_scope": 2, "pre_existing": 1, "scope_conflicts": 0 },
    "fixes": { "in_scope": 0, "pre_existing": 0 },
    "pre_existing_flagged": 1
  },
  "target_changes": { "modified": false, "files": [] },
  "paths": {
    "state_dir": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4",
    "artifacts_dir": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4/artifacts",
    "final_synthesis_artifact": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4/artifacts/iter1_4_synthesis.md"
  }
}
```

`--dry-run` retains the selected execution mode but sets `dry_run` to `true`,
`review_executed` to `false`, and `synthesis.executed_by` to `null`. Its normal
max-iteration result remains `incomplete-review`; it cannot be mistaken for a
completed real review. Unlike `--review-only`, dry-run calls no Agent and
produces no review conclusion, so it cannot replace a read-only review.

## Consuming the result from an outer LLM or Skill

An orchestrating LLM/Skill should read JSON fields instead of scraping terminal
text. For example: if `execution.review_executed` is false, report that no
review occurred; if `termination.category` is `review-only-findings-remain`,
open `paths.final_synthesis_artifact` and ask a human whether to start a new,
explicit `--apply-fixes` run; if the category is `clean`, continue the release.
Treat every other category as a stopped or failed workflow and surface
`termination.reason`. Do not infer success merely from the presence of a JSON
file.

Values come from the same parsed status blocks, tracking state, resolved CLI
configuration, and target snapshots used by the human-facing workflow. The
result writer does not parse terminal text.

If the destination cannot be atomically replaced (for example, it names a
directory), the review exit status is preserved and an explicit error is
written to stderr; persistence failures are never silently ignored.
