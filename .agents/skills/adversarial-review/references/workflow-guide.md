# Adversarial Review workflow guide

Load this reference only when baseline selection, result interpretation, or a
failed preflight needs more detail.

## Baseline examples

| Target Repo state | Adapter choice |
| --- | --- |
| Only staged, unstaged, or untracked work | `HEAD` |
| Committed feature work | Merge base with the known local default branch |
| Committed and uncommitted feature work | The same feature-branch merge base |
| User supplies `--base <ref>` | The explicit ref |

For a tracked feature branch, local and remote-tracking default refs must match.
The adapter discloses that it did not fetch. Detached HEAD, shallow history,
unknown default branches, missing remote refs, and divergent refs stop before
Agent calls; provide an explicit base or obtain separate authorization to
fetch/reconcile.

## Result statuses

- `clean`: the scoped review completed with no findings remaining.
- `review-only-findings-remain`: report findings; do not imply files changed.
- `apply-fixes-findings-remain`: report applied files separately from unresolved findings.
- `incomplete-review`: distinguish maximum iterations from an open circuit breaker and point to Synthesis/Artifacts.
- `invalid-invocation`: correct configuration or prerequisites before retrying.
- `agent-backend-failure`: resolve backend availability/authentication and retry.
- `write-boundary-violation`: stop and disclose the Target Repo diff; never silently revert user files.

Treat unsupported, malformed, or contradictory machine results as compatibility
errors. Do not infer success from terminal prose or internal tracking files.

## Preflight and compatibility troubleshooting

- Bash, `jq`, CLI-compatible timeout support, Agent backends, authentication,
  subscriptions, model quota, and network access are external prerequisites;
  Plugin installation does not provision or grant them.
- Ensure the CLI supports `--base`, `--target-dir`, reviewer slots, execution
  modes, Fixer selection, and `--result-file`.
- Ensure selected `claude` and `codex` executables exist and their read-only
  authentication checks pass.
- Install or authenticate only with separate user authorization.
- Ensure `jq` is available and use GNU `timeout` on Linux or compatible
  `gtimeout` from coreutils on macOS.
- A standalone Skill installation needs `adversarial_review.sh` on `PATH`,
  `ADVERSARIAL_REVIEW_BIN`, or an explicit `--cli` path.
- Verification accepts only the adapter's bounded argv shapes. Remove trailing
  runner, configuration, shell, or test-file selectors when rejected.
