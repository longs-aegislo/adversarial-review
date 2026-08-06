---
name: adversarial-review
description: Run a repository-level post-implementation adversarial review, review and fix completed changes, or perform a final adversarial check before a commit or PR. Do not use for ordinary code explanation, lightweight single-reviewer review, general debugging, or requests only to publish a PR.
---

# Adversarial Review

Run the installed Adversarial Review CLI through the bundled safe adapter. Keep
the CLI as the review engine; do not call Agent backends or parse tracking files
directly.

## Run the review

1. Treat the trusted current workspace as the Target Repo. Do not substitute
   this Skill directory, its plugin directory, or the installed CLI directory.
2. Let the adapter select a safe baseline unless the user supplied one. An
   explicit base always wins. Do not fetch to improve inference; stop when the
   adapter reports ambiguity.
3. Default to heterogeneous reviewer slots `claude` and `codex`. If the user
   explicitly requests `claude`/`claude` or `codex`/`codex`, allow that
   same-model redundancy and clearly report its lower review diversity. Never
   choose same-model redundancy merely because one backend is unavailable.
4. Use `review-only` for review requests, ambiguous wording, or any request
   that does not explicitly ask to fix the findings. Only a clear request such
   as “review and fix”, “apply the review fixes”, or equivalent write intent
   authorizes `apply-fixes`. Select the Fixer explicitly; never infer broader
   permission to modify `PRE_EXISTING` findings.

   Decision examples:

   | Request | Mode |
   | --- | --- |
   | “Review this and suggest fixes.” | `review-only` |
   | “Review this; do not change files.” | `review-only` |
   | “Review this and fix anything you find.” | `apply-fixes` with an explicit Fixer |
   | “Apply the fixes from the review.” | `apply-fixes` with an explicit Fixer |
5. From the Target Repo, run:

   ```bash
   <skill-directory>/scripts/run-review.sh [--base <baseline>]
   <skill-directory>/scripts/run-review.sh --apply-fixes --fixer <claude|codex> [--base <baseline>] [--verification-command <executable> --verification-arg <arg> ...]
   ```

   An installed Plugin always uses the runtime bundled in that same Plugin
   version and rejects runtime overrides. A source-repository Skill looks on
   `PATH`, then at that repository's root; there,
   `ADVERSARIAL_REVIEW_BIN` or `--cli <path>` remains available explicitly.

   The adapter performs read-only prerequisite checks, prints Target Repo,
   baseline, reviewer slots, and execution mode, then dry-runs the exact
   invocation. Start the real review only after it accepts the Review Scope.
6. For apply-fixes, inspect the Target Repo's instructions and documentation
   for safe verification commands. Select the highest relevant documented
   command (for example, the full test command instead of a single test). Pass
   its executable with `--verification-command` and each argument separately
   with a repeated `--verification-arg`; the adapter executes that argv directly
   and never evaluates shell syntax. Do not invent a command or install missing
   dependencies. If none is documented, omit the option; the adapter reports
   that none was provided.

7. Report the adapter's machine-result interpretation and its actionable next
   step. Do not reconstruct results from terminal prose or internal state.

Read [references/result-contract.md](references/result-contract.md) only when
diagnosing result compatibility or a stopped workflow.

Read [references/workflow-guide.md](references/workflow-guide.md) only when you
need baseline examples, result-status guidance, or prerequisite and
compatibility troubleshooting, including accepted verification-command shapes.

## Safety boundaries

Review authorization alone does not authorize commit, push, PR creation,
reset, clean, fetch, dependency installation, or changes to `PRE_EXISTING`
findings. In apply-fixes mode, report scoped fix counts, every machine-result
changed path, and every path under `Target Repo Diff` (from Git), and keep
remaining findings distinct. Do not start a real review after an empty or
invalid dry-run scope or with an unsupported result schema.
