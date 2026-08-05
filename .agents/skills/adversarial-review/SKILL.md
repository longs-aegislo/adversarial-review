---
name: adversarial-review
description: Run a repository-level adversarial code review, optionally applying fixes only after explicit review-and-fix authorization. Use only when the user explicitly invokes $adversarial-review; do not trigger for ordinary code explanation, debugging, or a lightweight single-pass review.
---

# Adversarial Review

Run the installed Adversarial Review CLI through the bundled safe adapter. Keep
the CLI as the review engine; do not call Agent backends or parse tracking files
directly.

## Run an explicit review

1. Treat the trusted current workspace as the Target Repo. Do not substitute
   this Skill directory, its plugin directory, or the installed CLI directory.
2. Let the adapter select a safe baseline unless the user supplied one. An
   explicit base always wins. Otherwise it uses `HEAD` for worktree-only work,
   or a known local default branch (`init.defaultBranch`, then `main`/`master`)
   for committed feature-branch work (including
   mixed committed and uncommitted changes). It stops before Agent calls for
   detached HEAD, shallow history, an unknown local default branch, or a
   missing/remote-only baseline. For a tracked feature branch it requires the
   corresponding remote-tracking default ref to exist and match the local
   default branch; an aligned pair may proceed, with a clear disclosure that no
   fetch occurred. A missing or divergent pair stops and asks for separate
   fetch authorization or an explicit base. The adapter never fetches itself.
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

   The adapter first looks for `adversarial_review.sh` on `PATH`, then for the
   CLI at the root of the repository containing this Skill. For a standalone
   Skill installation, set `ADVERSARIAL_REVIEW_BIN` to the installed CLI path
   or pass `--cli <path>`.

   Before a review invocation, the adapter checks the review CLI contract, the
   selected backend executables and authentication, `jq`, and timeout syntax
   compatibility with the CLI. It reports missing prerequisites without
   installing anything or changing credentials. The adapter then prints Target Repo, baseline,
   reviewer slots, and execution mode, performs a dry-run with the same
   explicit values, and starts the real review only after confirming a valid,
   non-empty, plausibly sized Review Scope. Empty, malformed, or unexpectedly
   large scopes stop before the real review. Every previewed path must also
   belong to the Git delta from the selected baseline, which rejects accidental
   whole-repository scopes even below the size limit.
6. For apply-fixes, inspect the Target Repo's instructions and documentation
   for safe verification commands. Select the highest relevant documented
   command (for example, the full test command instead of a single test). Pass
   its executable with `--verification-command` and each argument separately
   with a repeated `--verification-arg`; the adapter executes that argv directly
   and never evaluates shell syntax. Do not invent a command or install missing
   dependencies. If none is documented, omit the option; the adapter reports
   that none was provided.
7. Report the adapter's machine-result interpretation. Distinguish `clean`
   from `Findings remaining`, and include the final Synthesis and Artifacts
   paths it prints. Treat any other termination category as stopped or failed;
   surface its reason without inferring success from terminal prose.

Read [references/result-contract.md](references/result-contract.md) only when
diagnosing result compatibility or a stopped workflow.

## Safety boundaries

Review authorization alone does not authorize commit, push, PR creation,
reset, clean, fetch, dependency installation, or changes to `PRE_EXISTING`
findings. In apply-fixes mode, report every path under both `Applied fixes`
(from the machine result) and `Target Repo Diff` (from Git), and keep remaining
findings distinct. Do not start a real review after an empty/invalid dry-run
scope or with an unsupported result schema.
