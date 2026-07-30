**English** | [中文](guide.zh.md) | [日本語](guide.ja.md)

# Adversarial Review Guide

[Back to README](../README.md) · [Fork notes](fork-notes.md)

Multi-agent code review with Claude and GPT Codex in an adversarial debate loop.

Based on patterns from [asimov-ralph](https://github.com/frankbria/ralph-claude-code) and research on [AI Debate](https://arxiv.org/abs/2410.04663).

## Fork Notes

This fork's changes relative to upstream are maintained separately in
[Fork Notes](fork-notes.md).

## Concept

Two AI agents (Claude and GPT Codex) independently review code, then critique each other's findings through multiple rounds of debate. This adversarial process helps:

- **Find more issues**: Different models catch different problems
- **Eliminate false positives**: Cross-validation filters out incorrect findings
- **Build consensus**: Disagreements are resolved through structured debate
- **Improve confidence**: Issues both agents agree on are high-confidence fixes

## The 4-Phase Loop

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Independent Reviews                               │
│    Claude reviews code → claude_review.md                   │
│    Codex reviews code  → codex_review.md                    │
│    Agents are given a file path list (+ a git diff of what  │
│    changed since the last iteration) and read whichever     │
│    files they need themselves - full file contents are no   │
│    longer dumped into the prompt                             │
│    (runs in parallel)                                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 2: Cross-Review                                      │
│    Claude reviews Codex's findings → claude_on_codex.md     │
│    Codex reviews Claude's findings → codex_on_claude.md     │
│    (runs in parallel)                                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 3: Meta-Review                                       │
│    Claude responds to Codex's critique → claude_meta.md     │
│    Codex responds to Claude's critique → codex_meta.md      │
│    Each agent gets its own Phase 1 review, the other        │
│    agent's Phase 1 review, its own Phase 2 cross-review,    │
│    and the feedback it received - full context every time,  │
│    so findings can't silently drop out of consensus         │
│    (runs in parallel)                                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 4: Synthesis                                         │
│    Claude or Codex (your choice via --fixer) reviews all     │
│    debate artifacts and fixes IN_SCOPE findings.             │
│    PRE_EXISTING findings are reported but not changed unless │
│    --include-pre-existing was explicitly supplied            │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              Loop back to Phase 1 to verify fixes
              until both agents report NO_ISSUES
```

## Quick Start

```bash
# Clone or copy to your workspace
cd adversarial-review

# Run on a target project (prompts interactively for which agent
# implements Phase 4 fixes, if stdin is a TTY)
./adversarial_review.sh ../my-project

# With options
./adversarial_review.sh -m 5 -v ../my-project        # 5 iterations, verbose
./adversarial_review.sh -f codex ../my-project        # Codex implements fixes
./adversarial_review.sh -f claude ../my-project       # Claude implements fixes
./adversarial_review.sh --base main ../my-project     # Review branch changes only
./adversarial_review.sh --include-pre-existing ../my-project  # Fix historical findings too

# Dry run (see what would happen, no API calls)
./adversarial_review.sh --dry-run --base main ../my-project
```

## Requirements

- **claude CLI**: `npm install -g @anthropic-ai/claude-code`
- **codex CLI**: `npm install -g @openai/codex`
- **jq**: `brew install jq` (macOS) or `apt install jq` (Linux)
- **coreutils** (macOS only, for timeout): `brew install coreutils`

## Usage

```bash
./adversarial_review.sh [OPTIONS] <target_directory>

OPTIONS:
    -h, --help              Show help
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Additional Phase 1 criteria for this run
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    -f, --fixer AGENT       Who implements Phase 4 fixes: claude | codex
                            (if omitted, prompts interactively on a TTY;
                            defaults to codex when non-interactive)
    -b, --base REF          Review only files differing from this git ref,
                            including uncommitted and untracked source files
    --include-pre-existing  Allow Phase 4 to fix PRE_EXISTING findings too
                            (default: report them without applying changes)
    --status [DIR]          Show current status (for DIR if given)
    --reset [DIR]           Reset all state (for DIR if given)
    --reset-circuit [DIR]   Reset circuit breaker only (for DIR if given)
    --circuit-status [DIR]  Show circuit breaker status (for DIR if given)
    --dry-run               Show what would happen without executing
```

`--base` is optional and never inferred. When it is set, Phase 1 stays scoped
to reviewable source files that differ from the ref across committed, staged,
unstaged, and untracked work. The normal extension allowlist and generated/
vendored path exclusions still apply. An invalid ref, a non-git target, or an
empty resolved scope fails before any agent runs. Without `--base`, the
existing whole-directory scan is unchanged. Use it with `--dry-run` to inspect
the resolved mode, file count, and file list before spending API budget.

Every finding carries an `IN_SCOPE` or `PRE_EXISTING` tag. With `--base`, the
changed-file boundary guides the default classification; without it, agents
consult `git blame`/`git log` for the affected lines. Phase 4 normally fixes
only `IN_SCOPE` findings and lists historical findings separately. Use
`--include-pre-existing` only when you intentionally want both categories
implemented. Dry-run output shows which Phase 4 policy will be assembled, and
`--status <target_directory>` reports fixed/flagged counts by scope.

State is scoped per target directory (see State Directory below), so pass
the same `<target_directory>` you reviewed to `--status`/`--reset`/etc. to
inspect or reset that project's history specifically. Omitting it falls
back to a shared/global bucket kept only for backward compatibility.

## Project Structure

```
adversarial-review/
├── adversarial_review.sh    # Main script
├── lib/
│   ├── date_utils.sh        # Cross-platform date utilities
│   ├── circuit_breaker.sh   # Prevents runaway loops
│   └── response_analyzer.sh # Parses agent outputs
├── prompts/
│   ├── initial_review.md    # Phase 1: Independent review prompt
│   ├── cross_review.md      # Phase 2: Cross-review prompt
│   ├── meta_review.md       # Phase 3: Meta-review prompt
│   └── synthesis.md         # Phase 4: Synthesis prompt
└── state/                   # Per-target-directory state (gitignored)
    └── <project-slug>-<hash>/
        ├── artifacts/        # Agent outputs per iteration
        ├── logs/             # Execution logs
        ├── tracking.json     # State tracking
        └── .circuit_breaker.json
```

## State Directory

Each target directory you run against gets its own state folder under
`state/`, named from its basename plus a short hash of its full path (so
two differently-located folders that happen to share a name don't collide).
This means:

- Reviewing project A and then project B never mixes their `tracking.json`
  history, artifacts, or circuit breaker counters.
- An OPEN circuit breaker (or a leftover `--dry-run`) from one project can't
  block or pollute a run against a different one.
- `--status`/`--reset`/`--circuit-status`/`--reset-circuit` all take an
  optional target directory argument to scope to that project's state
  specifically.

## Circuit Breaker

Prevents runaway loops by detecting:

- **No progress**: 3 iterations with no fixes made
- **Persistent disagreement**: 5+ iterations where agents can't agree
- **Same issues**: 3+ iterations finding the same unfixable issues

```bash
# Check circuit breaker status for a specific project
./adversarial_review.sh --circuit-status ../my-project

# Reset if stuck
./adversarial_review.sh --reset-circuit ../my-project
```

## Customization

### Custom Review Prompts

```bash
# Add review criteria for this run
./adversarial_review.sh -p my_review_prompt.md ../project
```

The file is read once during argument validation and added as a delimited
criteria section to the built-in Phase 1 prompt. It does not replace the
agent-ID header, working-directory context, review scope, finding-scope rules,
or required status block, and it never modifies files under `prompts/`.
Missing, unreadable, and non-file paths fail before either agent is invoked.
Separate runs keep their criteria isolated from one another.

Phases 1-3 enforce read-only access at each backend's invocation boundary.
Claude receives only read/search tools plus narrowly approved `git log` and
`git blame` commands in non-interactive deny mode; Codex uses its read-only
sandbox. Only the agent selected for Phase 4 receives write access.

### Environment Variables

```bash
MAX_ITERATIONS=5      # Override max iterations
TIMEOUT_MINUTES=15    # Timeout per agent call
VERBOSE=1             # Enable verbose output
DRY_RUN=1             # Show what would happen
FIXER=codex           # Who implements Phase 4 fixes: claude | codex
```

## How It Works

### Agent Status Blocks

Each agent outputs a structured status block that gets parsed:

```
---REVIEW_STATUS---
ISSUES_FOUND: 3
CRITICAL_COUNT: 1
HIGH_COUNT: 1
MEDIUM_COUNT: 1
LOW_COUNT: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING, CLAUDE-3=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Found critical type mixing bug
---END_REVIEW_STATUS---
```

### Exit Conditions

The loop exits when:
1. **Both agents report NO_ISSUES** in Phase 1
2. **Synthesis completes** with EXIT_SIGNAL: true
3. **Max iterations reached**
4. **Circuit breaker opens** (stagnation detected)

### Artifacts

Each iteration produces:
- `iter{N}_1_claude_review.md` - Claude's initial review
- `iter{N}_1_codex_review.md` - Codex's initial review
- `iter{N}_2_claude_on_codex.md` - Claude's cross-review
- `iter{N}_2_codex_on_claude.md` - Codex's cross-review
- `iter{N}_3_claude_meta.md` - Claude's meta-review
- `iter{N}_3_codex_meta.md` - Codex's meta-review
- `iter{N}_4_synthesis.md` - Final synthesis and fixes

Every agent reply has a companion `*.invocation.json` recording the phase,
backend, native enforcement mode, allowed tools, and whether write access was
authorized. Review calls also retain structured `*.raw.log` events (Claude
`stream-json`, Codex `--json`) so denied or disallowed write attempts can be
audited; a detected Target change creates an
`iter{N}_phase_*_write_violation.json` fingerprint record and stops the run
without reverting user files.

Each Codex-generated file also has a companion `iter{N}_*_*.raw.log`.
`codex exec`'s stdout is the full agent transcript (reasoning
summaries, shell/tool calls, file dumps) - not just its final answer - so the
`.md` file is extracted via `codex exec -o` (`--output-last-message`) to hold
only the final reply, keeping it small when fed into later phases. The
`.raw.log` keeps the full transcript around for debugging.

## Research Background

This approach is based on:

- [D3: Debate, Deliberate, Decide](https://arxiv.org/abs/2410.04663) - Adversarial multi-agent evaluation framework
- [ChatEval](https://github.com/thunlp/ChatEval) - Multi-agent debate for LLM evaluation
- [AI Debate Research](https://arxiv.org/html/2410.04663v1) - Shows debating LLMs produce more accurate results

Key findings from research:
- Multi-agent debate reduces hallucinations and false positives
- 3-7 agents offer the best accuracy-to-cost ratio
- Adversarial validation improves consensus quality

## Cost Considerations

Each iteration makes 6 API calls (3 parallel pairs):
- Phase 1: 2 calls (Claude + Codex)
- Phase 2: 2 calls (Claude + Codex)
- Phase 3: 2 calls (Claude + Codex)
- Phase 4: 1 call (whichever agent `--fixer` selects)

With 3 iterations max, worst case is ~21 API calls per review.

Two things keep individual calls cheap:
- **Phase 1 no longer inlines full file contents.** Agents get a file path
  list (plus a `git diff` of what changed since the last iteration, from
  the second iteration onward) and read whatever files they actually need
  with their own tools, instead of having the whole codebase pasted into
  the prompt.
- **`--fixer` lets you route the heaviest step (Phase 4, which re-supplies
  the full Phase 1-3 debate history) to whichever agent has more quota
  available.** It defaults to Codex in non-interactive runs so Claude's
  usage isn't the one absorbing that cost by default.

## Contributing

This is an experimental prototype. Ideas for improvement:
- Add support for other models (Gemini, local LLMs)
- Implement weighted voting based on historical accuracy
- Add cost tracking and budgets
- Build a web UI for reviewing artifacts

## License

MIT
