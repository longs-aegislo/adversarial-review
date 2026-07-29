**English** | [中文](README.zh.md) | [日本語](README.ja.md)

# Adversarial Review

Multi-agent code review with Claude and GPT Codex in an adversarial debate loop.

Based on patterns from [asimov-ralph](https://github.com/frankbria/ralph-claude-code) and research on [AI Debate](https://arxiv.org/abs/2410.04663).

## Fork Notes

This repo is a fork of [alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review) (kept as the `upstream` remote). Since forking, this fork has fixed a number of bugs found by running the tool against a real Laravel project and has diverged from upstream in these ways:

- **Fixed `codex` invocation**: the original `run_codex()` used a stale CLI syntax (`-q --full-auto --prompt`) that no longer matches the current `codex` CLI. It now uses `codex exec -s <sandbox_mode> --skip-git-repo-check` with the prompt piped via stdin instead of passed as a positional argument (which was hitting `ARG_MAX`/ `timeout: Argument list too long` on large prompts).
- **Fixed source collection for non-JS/Python stacks**: `collect_source_code`/`collect_file_list` didn't exclude `vendor/`, `public/`, `storage/`, `bootstrap/cache/`, `dist/`, or `build/`, and had no PHP/Blade support - so on a Laravel project it was stuffing third-party vendored/minified JS into the prompt instead of the project's own source, which also blew past Claude's context limit.
- **Fixed Phase 3 losing the other agent's findings**: the meta-review prompt only re-supplied the feedback the other agent gave back, not that agent's original Phase 1 findings or your own Phase 2 cross-review of them. Since every phase is a fresh, stateless CLI call with no memory of earlier phases, this silently dropped one agent's entire set of findings from the final consensus. `run_phase_3()` now reconstructs full context for both agents.
- **Fixed `parse_status_block`'s "last block" extraction**: it used to concatenate every occurrence of a `---STATUS---...---END_STATUS---` marker pair in the text (including the prompt template's own baked-in EXAMPLE blocks), producing garbled/duplicate JSON. It's now an awk-based scanner that keeps only the last real block.
- **Added `-f/--fixer`**: lets you choose whether Claude or Codex implements Phase 4 fixes (interactively on a TTY, or via flag/env var), so you can route the most expensive step to whichever agent has more quota.
- **Reworked Phase 1 to stop inlining full file contents**: agents now get a file path list (plus a `git diff` against `HEAD` from the second iteration onward) and read whatever files they need themselves, instead of having the whole codebase pasted into the prompt - see the Cost Considerations section below.
- **Added per-phase issue summaries to terminal output**: each phase now prints the agents' one-line summaries, not just issue counts.
- **Scoped all state per target directory**: `tracking.json`, the circuit breaker, and `artifacts/` used to live at the repo root and were shared across every target you ever ran against - review a second project and its Phase 1 findings could land next to (or trip a circuit breaker left over from) the first one's runs. State now lives under `state/<slug>/`, keyed by the target directory's path, so projects can't cross-contaminate each other's history.
- **Fixed Phase 2/3 running in the wrong directory**: after Phase 1 was reworked to stop inlining file contents (previous bullet), Phase 2 (`run_phase_2()`) and Phase 3 (`run_phase_3()`) still never passed `target_dir` to `run_claude`/`run_codex`, so both agents defaulted to the *caller's* working directory instead of the project being reviewed - Claude would flag this and answer from text alone, while Codex would silently search whatever happened to be in the wrong directory and produce results about the wrong codebase entirely. Both phases now pass `target_dir` through, with Claude scoped to `--allowedTools "Read Glob Grep"`.
- **Fixed unfiltered untracked-file dump in `collect_recent_diff()`**: it copied every untracked, non-ignored file into the prompt with no path, extension, or size filtering - a real path for leaking unignored secrets or ingesting large/binary files. It now applies the same directory exclusions as source collection, skips common secret-like filenames, skips binary files, and caps each file's contents.
- **Fixed a misleading diff label**: the Phase 1 diff section was labeled "changes since the last review iteration," but since this tool never commits between iterations, it's actually the *cumulative* uncommitted diff across the whole run. The label and surrounding prompt text now say so explicitly.
- **Fixed colliding issue IDs between agents**: both agents always numbered their findings from `ISSUE-1`, so once merged in cross-review/synthesis, `ISSUE-1` from Claude and `ISSUE-1` from Codex were indistinguishable. Each agent is now told its own identity and prefixes every ID with an agent tag (`CLAUDE-1`, `CODEX-1`, ...).
- **Fixed Phase 2's "Additional Findings" silently dropping out of synthesis**: issues an agent found during cross-review (not in its own Phase 1 review) had no ID scheme and weren't covered by the synthesis ledger. They're now tagged `{AGENT}-ADD-N` and the Step 0 ledger in `synthesis.md` explicitly requires enumerating them alongside Phase 1 findings.

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
│    debate artifacts, decides which issues are valid, and    │
│    implements fixes with high/medium confidence              │
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

# Dry run (see what would happen, no API calls)
./adversarial_review.sh --dry-run ../my-project
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
    -p, --prompt FILE       Custom initial review prompt
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    -f, --fixer AGENT       Who implements Phase 4 fixes: claude | codex
                            (if omitted, prompts interactively on a TTY;
                            defaults to codex when non-interactive)
    --status [DIR]          Show current status (for DIR if given)
    --reset [DIR]           Reset all state (for DIR if given)
    --reset-circuit [DIR]   Reset circuit breaker only (for DIR if given)
    --circuit-status [DIR]  Show circuit breaker status (for DIR if given)
    --dry-run               Show what would happen without executing
```

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
# Use your own review criteria
./adversarial_review.sh -p my_review_prompt.md ../project
```

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

For each Codex-generated file above, a companion `iter{N}_*_*.raw.log` is also
written. `codex exec`'s stdout is the full agent transcript (reasoning
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
