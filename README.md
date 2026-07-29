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

Every finding is classified as `IN_SCOPE` or `PRE_EXISTING`. Phase 4 fixes
only `IN_SCOPE` findings by default and reports historical issues separately.
Pass `--include-pre-existing` only when you intentionally want both categories
fixed.

## Quick Start

```bash
cd adversarial-review

# Review a project
./adversarial_review.sh ../my-project

# Review only changes since a Git ref
./adversarial_review.sh --base main ../my-project

# Choose the Phase 4 fixer
./adversarial_review.sh --fixer codex ../my-project

# Preview scope and Phase 4 policy without API calls
./adversarial_review.sh --dry-run --base main ../my-project
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
