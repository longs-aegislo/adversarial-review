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
2. Select an explicit baseline. For uncommitted work, use `HEAD`. If the user
   supplied a base, pass it unchanged. If committed branch work requires a
   merge base and no reliable base is available, stop and ask instead of
   falling back to a whole-directory review.
3. Default to heterogeneous reviewer slots `claude` and `codex`. This Skill's
   explicit path requires both backends; report a missing dependency instead
   of silently reducing review diversity.
4. Use `review-only` unless the user separately and explicitly authorizes
   fixes. This version implements only the review-only path.
5. From the Target Repo, run:

   ```bash
   <skill-directory>/scripts/run-review.sh --base <baseline>
   ```

   The adapter prints Target Repo, baseline, reviewer slots, and execution mode
   before invoking the CLI. It then performs a dry-run with the same explicit
   values and starts the real review only after confirming a valid, non-empty
   Review Scope.
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
