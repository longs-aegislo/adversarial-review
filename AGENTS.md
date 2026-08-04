# Repository Instructions

> 若当前目录存在 `AGENTS.local.md`，也一并读取——其中是本机/个人账号相关、
> 不适合共享或提交的指令，作为对本文件的补充。

## GitHub comment formatting and signature

- Codex 发布或更新 GitHub 评论时，正文必须使用实际换行，不得把字面量 `\n` 当作换行发送。
- 优先使用能原样保留多行内容的方式（例如 `--body-file`）；发布后确认评论中没有意外显示字面量 `\n`。
- Codex 发布的 GitHub 评论末尾空一行并署名 `by Codex`。

## Documentation synchronization

- 功能或用户可见行为改修完成后，必须同步检查并更新 `README.md`、`README.zh.md`、`README.ja.md` 及其对应的三语详细文档，确保功能、CLI 和行为说明保持一致；即使无需修改，也要确认三语文档没有落后。

## Agent skills

### Issue tracker

GitHub Issues via the `gh` CLI (`origin` -> `longs-aegislo/adversarial-review`). See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Repository Overview

Adversarial Review is a multi-agent code review tool that uses Claude and GPT Codex in an adversarial debate loop. Two AI agents independently review code, critique each other's findings, and reach consensus through structured debate.

Based on patterns from [asimov-ralph](https://github.com/frankbria/ralph-claude-code).

## Architecture

### Main Script: `adversarial_review.sh`

The main entry point (~820 lines). Orchestrates the 4-phase review loop:

1. **Phase 1: Independent Reviews** - Claude and Codex review code in parallel
2. **Phase 2: Cross-Review** - Each reviews the other's findings
3. **Phase 3: Meta-Review** - Each responds to feedback on their review
4. **Phase 4: Synthesis** - The selected fixer either reports unresolved
   findings read-only or implements permitted fixes, according to execution mode

### Library Components (`lib/`)

- **circuit_breaker.sh** - Prevents runaway loops by detecting:
  - No progress after N iterations (default: 3)
  - Persistent disagreement (default: 5 iterations)
  - Same issues found repeatedly (default: 3 times)

- **response_analyzer.sh** - Parses agent outputs:
  - Detects NO_ISSUES responses
  - Extracts structured status blocks
  - Compares agent agreement levels

- **date_utils.sh** - Cross-platform date utilities:
  - ISO timestamp generation
  - Epoch time calculations

### Prompt Templates (`prompts/`)

Each phase has a dedicated prompt template:
- `initial_review.md` - Code review criteria and output format
- `cross_review.md` - How to analyze another agent's findings
- `meta_review.md` - How to respond to feedback
- `synthesis.md` - How to synthesize and implement fixes

All prompts include structured status blocks that get parsed:
```
---REVIEW_STATUS---
ISSUES_FOUND: 3
EXIT_SIGNAL: false
SUMMARY: Found critical issues
---END_REVIEW_STATUS---
```

## Key Commands

```bash
# Run review on a project
./adversarial_review.sh ../my-project

# With options
./adversarial_review.sh -m 5 -v -t 15 ../my-project  # 5 iters, verbose, 15m timeout

# Dry run (no API calls)
./adversarial_review.sh --dry-run ../my-project

# Status and management
./adversarial_review.sh --status
./adversarial_review.sh --reset
./adversarial_review.sh --circuit-status
./adversarial_review.sh --reset-circuit
```

## State Files

- `tracking.json` - Main state tracking (iteration, status, history)
- `.circuit_breaker.json` - Circuit breaker state
- `.circuit_breaker_history.json` - State transition history
- `artifacts/` - All agent outputs per iteration

## Artifacts Naming Convention

```
iter{N}_{phase}_{agent}_{type}.md

Examples:
- iter1_1_claude_review.md      # Phase 1, Claude's initial review
- iter1_1_codex_review.md       # Phase 1, Codex's initial review
- iter1_2_claude_on_codex.md    # Phase 2, Claude reviewing Codex
- iter1_2_codex_on_claude.md    # Phase 2, Codex reviewing Claude
- iter1_3_claude_meta.md        # Phase 3, Claude's meta-review
- iter1_3_codex_meta.md         # Phase 3, Codex's meta-review
- iter1_4_synthesis.md          # Phase 4, Claude's synthesis
```

Every agent reply has a companion `*.invocation.json` that records its phase,
effective execution mode, native permission/sandbox mode, and whether write
access was actually authorized.
Review-phase Claude and Codex calls also retain structured `*.raw.log` events
for denied-write auditing. All four phases invoke agents through
`run_backend()`, which dispatches to the backend-specific runner and requires
the matching audit hook in read-only mode. Codex's raw stream is not just the
final answer, so `run_codex()` uses `codex exec -o <file>`
(`--output-last-message`) to write only the final reply to the `.md` file fed
into later prompts. Raw transcripts remain diagnostic artifacts and are never
concatenated into later prompts.

## Dependencies

- **claude CLI**: `npm install -g @anthropic-ai/claude-code`
- **codex CLI**: `npm install -g @openai/codex`
- **jq**: JSON processing (`brew install jq`)
- **coreutils** (macOS): For timeout command (`brew install coreutils`)

## Known Issues / TODOs

1. **macOS compatibility**: Uses `gtimeout` from coreutils instead of `timeout`.
   No maintainer environment currently has (or is expected to have) macOS, so
   this path is untested by the maintainer and relies on community testing
   and feedback.
2. **Tests**: `tests/` has bats-style suites covering backend dispatch,
   base-scope, response-analyzer, execution modes, include-pre-existing, and
   the CLI contract and machine-readable results (81 cases total). See
   `tests/test_*.sh`.
3. **Codex CLI flags**: May need adjustment based on actual codex CLI behavior
4. **Cost tracking**: Not implemented - each iteration is ~6 API calls
5. **Prompt bloat from Codex transcripts** (fixed): earlier versions fed each
   phase's raw `codex exec` stdout (full reasoning/tool-call transcript,
   sometimes 100s of KB) into every later phase's prompt, snowballing context
   size iteration over iteration. `run_codex()` now extracts only the final
   reply via `-o`/`--output-last-message`; see Artifacts Naming Convention.

## Development Notes

### Bash Gotchas Fixed

1. **Arithmetic increment with set -e**: `((iteration++))` returns 1 when incrementing from 0, which triggers `set -e`. Fixed with `((iteration++)) || true`.

2. **macOS head -z**: GNU `head -z` for null-delimited input doesn't exist on macOS. Replaced with line-based reading with counters.

3. **Background job stdin**: When running agents in parallel with `&`, ensure stdin handling doesn't block.

### Adding New Agents

To add a third agent (e.g., Gemini):
1. Add `run_gemini()` and `audit_gemini_review_transcript()` functions
2. Register both read-only and writable modes in `run_backend()` so the
   read-only audit cannot be skipped
3. Update phases to run the third agent in parallel
4. Update cross-review to have 3-way comparisons
5. Update synthesis to consider all three perspectives

### Customizing Review Criteria

Edit `prompts/initial_review.md` to change what gets reviewed:
- Add domain-specific checks
- Adjust severity classifications
- Modify output format

## Related Projects

- [asimov-ralph](https://github.com/frankbria/ralph-claude-code) - The autonomous dev loop this is based on
- [D3 Framework](https://arxiv.org/abs/2410.04663) - Academic research on adversarial AI debate
- [ChatEval](https://github.com/thunlp/ChatEval) - Multi-agent debate for evaluation
