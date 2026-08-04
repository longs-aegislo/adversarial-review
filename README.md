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

# Preview scope and Phase 4 policy without API calls
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## Requirements

- **claude CLI**: `npm install -g @anthropic-ai/claude-code`
- **codex CLI**: `npm install -g @openai/codex`
- **jq**: `brew install jq` (macOS) or `apt install jq` (Linux)
- **coreutils** (macOS only, for timeout): `brew install coreutils`

## Documentation

- [Detailed guide](docs/guide.md) — complete CLI reference, review phases,
  state management, artifacts, customization, and cost notes
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
