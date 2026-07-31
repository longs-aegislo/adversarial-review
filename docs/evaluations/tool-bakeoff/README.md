# Local multi-agent review tool bake-off

Date: 2026-07-29

## Decision

No evaluated external tool is a drop-in replacement for this project under the
agreed constraints. Keep this project active and proceed to a configurable
reviewer/backend design, but fix the review-phase write boundary and destructive
`--prompt` behavior before expanding the architecture.

[Open Code Review](https://github.com/spencermarx/open-code-review) is the
closest replacement when same-host reviewer instances are acceptable. It did
not enter the formal bake-off because its current release cannot run the
uniform Claude CLI + Codex CLI reviewer pair. Its Codex/Gemini reviewer-spawn
adapters remain an unimplemented design.

## Agreed evaluation rules

An external candidate had to:

1. reuse at least one existing CLI subscription without a mandatory API key;
2. review an arbitrary local Git diff, not only a GitHub PR;
3. provide real reviewer-to-reviewer discourse;
4. keep source review read-only by default and retain auditable individual,
   disagreement, and final artifacts; and
5. support a smooth fix and re-review cycle.

The formal comparison also required the same target, diff, requirements, scope
brief, and exactly two reviewers: Claude CLI and Codex CLI. A fixer/synthesizer
was allowed only in the fix stage. Native orchestration and prompts were left
intact except for supplying the same case brief.

The decision order was:

1. scope or unauthorized-write violation (automatic failure);
2. hidden tests after the fix loop;
3. known-defect recall;
4. false positives;
5. discourse and auditability; then
6. setup cost, duration, and calls.

## Candidate pre-screen

The repositories were inspected at these commits:

| Candidate | Commit | Result |
| --- | --- | --- |
| [Chorus](https://github.com/chorus-codes/chorus/tree/dc1c91b5abf26eaaefc468f2934be4743f05709e) | `dc1c91b` (v0.8.64) | Rejected before model calls |
| [Open Code Review](https://github.com/spencermarx/open-code-review/tree/fee6905939eaa804dfd90d815cecbcb26f600d32) | `fee6905` (assets synced to 2.5.0) | Passed the product gates, but could not satisfy the uniform backend condition |
| [coding-review-agent-loop](https://github.com/wwind123/coding-review-agent-loop/tree/7cbfc282135feecb2b947441c8f14a3007fd45bc) | `7cbfc28` | Rejected before model calls |

### Chorus

- Existing Claude, Codex, and Gemini CLI subscriptions are supported.
- Strict review permissions and telemetry opt-out are available.
- The `review-only` template describes independent, single-pass reviews rather
  than reviewer-to-reviewer discourse.
- The native write → review → fix → re-review flow is still listed for v0.9,
  not the inspected release.

Primary evidence:
[README permissions, telemetry, and roadmap](https://github.com/chorus-codes/chorus/blob/dc1c91b5abf26eaaefc468f2934be4743f05709e/README.md),
[review-only template](https://github.com/chorus-codes/chorus/blob/dc1c91b5abf26eaaefc468f2934be4743f05709e/templates/review-only.yaml),
and
[code-review template](https://github.com/chorus-codes/chorus/blob/dc1c91b5abf26eaaefc468f2934be4743f05709e/templates/code-review.yaml).

### Open Code Review

- It reviews staged changes, commits, and branches and retains round artifacts.
- It has explicit structured discourse and a separate address-feedback flow.
- It supports multiple instances and per-reviewer models inside the active host.
- In the inspected release, Claude/OpenCode hosts spawn their own subagents.
  Codex and Gemini per-reviewer child adapters are proposed but their task list
  is unchecked. Consequently, it cannot run a heterogeneous Claude CLI + Codex
  CLI reviewer pair under the agreed uniform condition.
- The local Node.js 20.20.2 runtime is also below its documented Node.js 22.5
  minimum, adding setup cost but not causing the rejection.

Primary evidence:
[README workflow and discourse](https://github.com/spencermarx/open-code-review/blob/fee6905939eaa804dfd90d815cecbcb26f600d32/README.md),
[host-aware spawning proposal](https://github.com/spencermarx/open-code-review/blob/fee6905939eaa804dfd90d815cecbcb26f600d32/openspec/changes/evolve-phase4-host-aware-spawning/proposal.md),
and
[unimplemented adapter tasks](https://github.com/spencermarx/open-code-review/blob/fee6905939eaa804dfd90d815cecbcb26f600d32/openspec/changes/evolve-phase4-host-aware-spawning/tasks.md).

### coding-review-agent-loop

- It reuses authenticated Claude, Codex, and Gemini-compatible CLIs and has a
  mature coder → reviewers → fix loop.
- Its CLI modes start from a GitHub issue, PR, task, or issue discussion.
  Review/fix state is durable in GitHub metadata.
- The discussion mode provides genuine debate, but it debates an issue rather
  than reviewing an arbitrary local diff.
- Running its code-review loop would require the remote GitHub writes that the
  evaluation explicitly prohibited.

Primary evidence:
[README](https://github.com/wwind123/coding-review-agent-loop/blob/7cbfc282135feecb2b947441c8f14a3007fd45bc/README.md),
[local loop design](https://github.com/wwind123/coding-review-agent-loop/blob/7cbfc282135feecb2b947441c8f14a3007fd45bc/docs/local_agent_loop.md),
and
[CLI modes](https://github.com/wwind123/coding-review-agent-loop/blob/7cbfc282135feecb2b947441c8f14a3007fd45bc/src/coding_review_agent_loop/cli.py).

## Reproducible fixture

The fixture is documented at
[`benchmarks/tool-bakeoff/README.md`](../../../benchmarks/tool-bakeoff/README.md).
It creates three zero-dependency JavaScript Git repositories with a
`benchmark-base` tag:

| Case | Purpose | Known defects |
| --- | --- | ---: |
| `pure-review` | Straight correctness review | 3 in-scope regressions |
| `scope` | New versus historical finding handling | 1 in-scope, 1 pre-existing |
| `fix-loop` | Requirements-driven repair | 3 contract defects |

Visible tests pass in every initial target. The external validator fails on the
known defects before review and is not copied into the target repository.

## Current-project baseline

Environment:

- Claude Code 2.1.220
- Codex CLI 0.145.0
- Node.js 20.20.2
- `--base benchmark-base --max-iters 1 --fixer codex`
- 7 model calls per formal run

| Case | Recall | False positives | Final validation | Scope result | Duration |
| --- | --- | --- | --- | --- | ---: |
| `pure-review` | 3/3 | 0 blocking; one pre-existing test-gap note | Passed | No finding-scope violation | 503.20 s |
| `scope` | 2/2 classified correctly | 0 | Passed | Old defect reported and left unchanged | 511.88 s |
| `fix-loop` | 3/3 contract defects | One non-blocking naming judgment and one test-gap note | Passed | No unrelated source change | 497.87 s |

Formal total: 3 runs, 21 model calls, 1512.95 seconds (25m 12.95s).

One permitted setup retry was used on `pure-review`. The first attempt spent
144.63 seconds and made 3 successful Claude calls plus 4 failed Codex startup
attempts. Codex could not initialize inside the managed filesystem sandbox, so
formal runs were authorized outside that wrapper while writes remained limited
to the temporary target and this artifact directory.

The reviewers did perform substantive cross-checking: they referenced the
other reviewer's concrete IDs, verified or deduplicated claims, and preserved
the test-coverage notes separately from production defects.

## Baseline defects exposed by the evaluation

### Review phases are not reliably read-only

Claude is launched with `--allowedTools`, which auto-allows the listed tools
but does not form a deny-list for every other tool. When the custom case brief
said to correct violations, Claude modified the target during Phase 1. The
concurrent Codex reviewer could then inspect an already-corrected worktree.

This breaks both the intended independent-review phase boundary and the agreed
read-only safety gate. The final source results were correct, but the
`scope` and `fix-loop` runs fail the safety criterion.

### `--prompt` destructively overwrites the built-in prompt

`adversarial_review.sh --prompt FILE` copies `FILE` onto the repository's
tracked `prompts/initial_review.md`. It does not restore the original after the
run. Because the benchmark briefs did not contain the built-in status-block
contract, the console and `tracking.json` reported zero Phase 1 issues even
when both raw reviews contained findings.

The tracked prompt was restored after the runs. The model outputs and hidden
validation remain usable, but the structured Phase 1 counts from these runs
must not be used.

## Artifacts

Raw reviewer replies, Codex transcripts, synthesis output, tracking state, and
the failed setup attempt are retained under
[`artifacts/current`](artifacts/current/). Final target diffs are preserved in:

- [`results/pure-review.patch`](results/pure-review.patch)
- [`results/scope.patch`](results/scope.patch)
- [`results/fix-loop.patch`](results/fix-loop.patch)

The raw files were scanned for common credential patterns before inclusion.
They contain temporary local paths but no detected tokens, passwords, or API
keys.

## Product implication

There is overlap, but not a complete existing wheel for this project's desired
combination: heterogeneous subscription-backed local CLIs, explicit
reviewer-to-reviewer challenge, local Git diff scope, auditable artifacts, and
a scope-aware fix loop.

The next product work should be ordered as follows:

1. enforce a genuinely read-only Phase 1–3 boundary;
2. make `--prompt` non-destructive while preserving the status contract;
3. add regression tests for both behaviors; then
4. design configurable reviewer slots and backends, with heterogeneous
   reviewers preferred and same-model redundancy documented as a lower-
   diversity mode.

Do not archive the project based on the existing alternatives. Also do not
expand the backend architecture before the two baseline safety defects are
fixed.
