**English** | [中文](README.zh.md) | [日本語](README.ja.md)

# Adversarial Review

Multi-agent code review with Claude and GPT Codex in an adversarial debate
loop.

Based on patterns from
[asimov-ralph](https://github.com/frankbria/ralph-claude-code) and research on
[AI Debate](https://arxiv.org/abs/2410.04663).

## Concept

Claude and Codex independently review a target project, challenge each
other's findings, reconcile disagreements, and let a selected fixer implement
the agreed changes.

The loop has four phases:

1. Independent reviews
2. Cross-review
3. Meta-review and consensus
4. Synthesis and implementation

Every finding is classified as `IN_SCOPE` or `PRE_EXISTING`. In apply-fixes
mode, Phase 4 fixes only `IN_SCOPE` findings by default and reports historical
issues separately. Pass `--include-pre-existing` only when you intentionally
want both categories fixed.

Phases 1-3 run with read-only agent permissions. Only apply-fixes mode gives
the selected Phase 4 fixer write access. `--prompt FILE` adds Phase 1 review
criteria for that run without replacing the mandatory issue, scope, or status
protocol.

Pass `--review-only` or `--apply-fixes` to explicitly declare whether this
invocation runs Phase 4 as read-only synthesis or writable fix application.
In review-only mode, all four phases run, Phase 4 uses the same read-only
backend boundary as Phases 1-3, and its report separates unresolved
`IN_SCOPE` and `PRE_EXISTING` findings without modifying the target. The two
flags are mutually exclusive and are validated before any dependency check or
agent call. Omitting both keeps today's implicit apply-fixes behavior and
prints a migration notice. New automation, skills, and plugins should pass one
of these flags explicitly.

Every invocation now requires two reviewer backends and a target directory:
`slot-a slot-b target-dir`. Each value also has a long-flag form. The slots
accept `claude` or `codex`; assigning the same backend to both is supported
with a reduced-diversity warning.

## Quick Start

```bash
cd adversarial-review

# Review a project
./adversarial_review.sh claude codex ../my-project

# Review only changes since a Git ref
./adversarial_review.sh --base main claude codex ../my-project

# Choose the Phase 4 fixer
./adversarial_review.sh --fixer codex claude codex ../my-project

# Add review criteria for this run
./adversarial_review.sh --prompt security-review.md claude codex ../my-project

# Write an atomic JSON result for CI or other automation
./adversarial_review.sh --apply-fixes --result-file review-result.json claude codex ../my-project

# Preview scope and Phase 4 policy without API calls
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## Automation contract

| Mode | Agent calls | Target writes | Completed-with-findings status |
| --- | --- | --- | ---: |
| `--review-only` | All four phases | Never | `10` |
| `--apply-fixes` | Review phases plus permitted fix/verification work | Phase 4 may write | `11` |
| neither flag (legacy) | Same as `--apply-fixes` | Phase 4 may write | `11` |

The legacy implicit mode prints a migration notice and may be removed; new
automation should always select a mode. `--dry-run` is only a preview: it calls
no Agent and produces no review conclusion, so it cannot replace
`--review-only`.

Stable exit statuses are `0` clean, `10` review-only findings, `11` apply-fixes
findings, `12` incomplete review, `64` invalid invocation, `70` Agent/backend
failure, and `77` write-boundary violation. Add `--result-file PATH` for the
complete versioned JSON result; see the [result-file contract](docs/result-file.md)
for every field, an example object, and outer LLM/Skill routing guidance.

## Requirements

- **claude CLI**: `npm install -g @anthropic-ai/claude-code`
- **codex CLI**: `npm install -g @openai/codex`
- **jq**: `brew install jq` (macOS) or `apt install jq` (Linux)
- **coreutils** (macOS only, for timeout): `brew install coreutils`

## Install as a local Codex Plugin

This repository is also a self-contained local marketplace. From any isolated
or regular Codex profile, register this checkout and install its Plugin:

```bash
codex plugin marketplace add /absolute/path/to/adversarial-review
codex plugin list --marketplace adversarial-review-local --available
codex plugin add adversarial-review@adversarial-review-local
```

For a Git-backed, reproducible install, replace the local path with
`longs-aegislo/adversarial-review` and pin it with `--ref <tag-or-commit>`.
Confirm the selected version with `codex plugin list --available --json`. To
follow a branch, run `codex plugin marketplace upgrade adversarial-review-local`
and then repeat `codex plugin add adversarial-review@adversarial-review-local`;
the reinstall replaces the complete versioned package without touching review
state or Artifacts for any Target Repo.

Start a new Codex thread after installation and invoke `$adversarial-review`
from the Target Repo. The installed Plugin contains exactly one Skill plus its
matching CLI runtime, libraries, prompts, and references; it does not depend on
this source checkout or a personal Skill installation. Reviews default to
`review-only`. Only an explicit `apply-fixes` request can authorize Target Repo
changes. `compatibility.json` binds the Plugin version to the jointly tested
CLI result schema, Skill workflow, and installation layout.

Plugin installation does not install or configure Bash, `jq`, timeout support,
Agent backends, authentication, subscriptions, model quota, or network access.
Those remain external prerequisites and are checked when the Skill is invoked,
before any review Agent starts. A single available backend is sufficient only
when both reviewer slots explicitly select it; the Adapter reports this as
lower-diversity same-model redundancy.

## Documentation

- [Repository-level Adversarial Review Skill](.agents/skills/adversarial-review/SKILL.md) —
  discoverable for explicit or clearly implied post-implementation adversarial
  review and pre-commit/PR checks; it defaults to review-only and applies fixes
  only for clear review-and-fix requests with a named Fixer; it safely infers or accepts a baseline and previews a guarded file list
  after read-only CLI/backend/authentication/dependency preflight, before running
  Agents, then strictly validates versioned machine results and gives distinct,
  actionable summaries for clean, findings, incomplete, policy, and infrastructure outcomes. Ordinary explanation,
  lightweight single-reviewer review, debugging, and PR publication do not trigger it; the Skill remains a thin CLI Adapter.
- [Detailed guide](docs/guide.md) — complete CLI reference, review phases,
  state management, artifacts, customization, and cost notes
- [Process exit statuses](docs/exit-statuses.md) — stable statuses for CI and
  other automation
- [Machine-readable result file](docs/result-file.md) — versioned atomic JSON
  output for every termination path
- [Fork notes](docs/fork-notes.md) — changes and fixes relative to upstream
- [Domain glossary](CONTEXT.md) — terminology used by the implementation
- [Tool bake-off](docs/evaluations/tool-bakeoff/README.md) — comparison with
  Chorus, Open Code Review, and coding-review-agent-loop, including reproducible
  fixtures and raw evidence

## Contributing

This is an experimental prototype. Ideas for improvement include additional
review agents, accuracy-based voting, cost controls, and better artifact
visualization.

## License

MIT
