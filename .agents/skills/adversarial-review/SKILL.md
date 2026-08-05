---
name: adversarial-review
description: Run a repository-level adversarial code review after implementation or before a commit/PR, including explicit review-only requests. Use only when the user explicitly invokes $adversarial-review; do not trigger for ordinary code explanation, debugging, or a lightweight single-pass review.
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
4. Use `review-only` unless the user separately and explicitly authorizes
   fixes. This version implements only the review-only path.
5. From the Target Repo, run:

   ```bash
   <skill-directory>/scripts/run-review.sh [--base <baseline>]
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
6. Report the adapter's machine-result interpretation. Distinguish `clean`
   from `Findings remaining`, and include the final Synthesis and Artifacts
   paths it prints. Treat any other termination category as stopped or failed;
   surface its reason without inferring success from terminal prose.

Read [references/result-contract.md](references/result-contract.md) only when
diagnosing result compatibility or a stopped workflow.

## Safety boundaries

Do not commit, push, create a PR, reset, clean, fetch, install dependencies, or
modify the Target Repo as part of this Skill. Do not start a real review after
an empty/invalid dry-run scope or with an unsupported result schema.
