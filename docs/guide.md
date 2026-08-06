**English** | [中文](guide.zh.md) | [日本語](guide.ja.md)

# Adversarial Review Guide

[Back to README](../README.md) · [Fork notes](fork-notes.md)

Multi-agent code review with Claude and GPT Codex in an adversarial debate loop.

Based on patterns from [asimov-ralph](https://github.com/frankbria/ralph-claude-code) and research on [AI Debate](https://arxiv.org/abs/2410.04663).

## Fork Notes

This fork's changes relative to upstream are maintained separately in
[Fork Notes](fork-notes.md).

## Concept

Two configurable reviewer slots, each backed by Claude or Codex, independently
review code and then critique each other's findings through multiple rounds of debate.
The slots may use different backends or the same backend. This adversarial process helps:

- **Find more issues**: Different models catch different problems
- **Eliminate false positives**: Cross-validation filters out incorrect findings
- **Build consensus**: Disagreements are resolved through structured debate
- **Improve confidence**: Issues both agents agree on are high-confidence fixes

## The 4-Phase Loop

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Independent Reviews                               │
│    Slot A reviews code → <backend>_review.md                │
│    Slot B reviews code → <backend>_review.md                │
│    Agents are given a file path list (+ a git diff of what  │
│    changed since the last iteration) and read whichever     │
│    files they need themselves - full file contents are no   │
│    longer dumped into the prompt                             │
│    (runs in parallel)                                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 2: Cross-Review                                      │
│    Slot A reviews slot B's findings                         │
│    Slot B reviews slot A's findings                         │
│    (runs in parallel)                                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 3: Meta-Review                                       │
│    Slot A responds to slot B's critique                     │
│    Slot B responds to slot A's critique                     │
│    Each agent gets its own Phase 1 review, the other        │
│    agent's Phase 1 review, its own Phase 2 cross-review,    │
│    and the feedback it received - full context every time,  │
│    so findings can't silently drop out of consensus         │
│    (runs in parallel)                                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 4: Synthesis                                         │
│    Claude or Codex (your choice via --fixer) reviews all     │
│    debate artifacts. Review-only reports unresolved findings │
│    without writes; apply-fixes fixes IN_SCOPE by default.     │
│    PRE_EXISTING remains report-only unless explicitly opted in│
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              Apply-fixes may loop to verify fixes;
              review-only completes after synthesis
```

## Quick Start

```bash
# Clone or copy to your workspace
cd adversarial-review

# Run on a target project (prompts interactively for which agent
# implements Phase 4 fixes, if stdin is a TTY)
./adversarial_review.sh claude codex ../my-project

# With options
./adversarial_review.sh -m 5 -v claude codex ../my-project
./adversarial_review.sh -f codex claude codex ../my-project
./adversarial_review.sh -f claude claude codex ../my-project
./adversarial_review.sh --base main claude codex ../my-project
./adversarial_review.sh --include-pre-existing claude codex ../my-project

# Dry run (see what would happen, no API calls)
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## Requirements

- **claude CLI**: `npm install -g @anthropic-ai/claude-code`
- **codex CLI**: `npm install -g @openai/codex`
- **jq**: `brew install jq` (macOS) or `apt install jq` (Linux)
- **coreutils** (macOS only, for timeout): `brew install coreutils`

## Usage

```bash
./adversarial_review.sh [OPTIONS] <slot_a> <slot_b> <target_directory>

OPTIONS:
    -h, --help              Show help
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Additional Phase 1 criteria for this run
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    -f, --fixer AGENT       Who implements Phase 4 fixes: claude | codex
                            (if omitted, prompts interactively on a TTY;
                            defaults to codex when non-interactive)
    --slot-a AGENT          Backend for reviewer slot A: claude | codex
    --slot-b AGENT          Backend for reviewer slot B: claude | codex
    --target-dir PATH       Project directory to review
    -b, --base REF          Review only files differing from this git ref,
                            including uncommitted and untracked source files
    --include-pre-existing  Allow Phase 4 to fix PRE_EXISTING findings too
                            (default: report them without applying changes)
    --review-only           Run Phase 4 through the read-only backend path;
                            report unresolved findings without target changes
                            (mutually exclusive with --apply-fixes)
    --apply-fixes           Declare intent for Phase 4 to keep today's write
                            access (mutually exclusive with --review-only)
    --result-file PATH      Atomically write one versioned JSON result on exit
    --status                Show current status for the required target
    --reset                 Reset all state for the required target
    --reset-circuit         Reset circuit breaker for the required target
    --circuit-status        Show circuit breaker status for the required target
    --dry-run               Preview without Agent calls or review conclusions;
                            not a substitute for --review-only
```

For automation, see the stable [process exit status contract](exit-statuses.md).
It distinguishes clean completion, findings that remain, incomplete reviews,
invalid invocations, backend failures, and write-boundary violations.

Add `--result-file PATH` when automation also needs structured details. Once
the option has been parsed, every later termination path atomically replaces
the destination with one schema-versioned JSON object while terminal output
remains unchanged. See the [machine-readable result contract](result-file.md)
for the schema, data sources, target-change list, and dry-run semantics.

The three required inputs may each use their positional or long-flag form in
any mixture. Both slots may use the same backend; the run continues with a
warning that review diversity is reduced. The old single-positional form is
rejected rather than reinterpreting the target path as slot A.

`--base` is optional and never inferred. When it is set, Phase 1 stays scoped
to reviewable source files that differ from the ref across committed, staged,
unstaged, and untracked work. The normal extension allowlist and generated/
vendored path exclusions still apply. An invalid ref, a non-git target, or an
empty resolved scope fails before any agent runs. Without `--base`, the
existing whole-directory scan is unchanged. Use it with `--dry-run` to inspect
the resolved mode, file count, and file list before spending API budget.

Every finding carries an `IN_SCOPE` or `PRE_EXISTING` tag. With `--base`, the
changed-file boundary guides the default classification; without it, agents
consult `git blame`/`git log` for the affected lines. In apply-fixes mode,
Phase 4 normally fixes only `IN_SCOPE` findings and lists historical findings
separately. Use `--include-pre-existing` only when you intentionally want both
categories implemented. Dry-run output shows which Phase 4 policy will be assembled, and
`--status <slot_a> <slot_b> <target_directory>` reports fixed/flagged counts by scope.

`--review-only` and `--apply-fixes` let a caller explicitly declare whether
Phase 4 performs read-only synthesis or applies fixes with write access. They
are mutually exclusive, and specifying both fails before any dependency check
or agent call. Review-only still executes all four phases, routes Phase 4
through the same read-only backend contract as Phases 1-3, and reports
unresolved `IN_SCOPE` and `PRE_EXISTING` findings in separate sections without
claiming they were fixed. Omitting both flags keeps today's implicit
apply-fixes behavior but prints a migration notice, so new automation, skills,
and plugins should pass one explicitly. This compatibility default may be
removed in a future version.

| Mode | Runs Agents? | Phase 4 target access | Purpose |
| --- | --- | --- | --- |
| `--review-only` | Yes, all four phases | Read-only | Produce an actual review and unresolved-finding report. |
| `--apply-fixes` | Yes | Writable | Apply permitted fixes and report anything remaining. |
| `--dry-run` (with either mode) | No | No Agent access | Preview scope and policy only; it produces no review conclusion and cannot replace `--review-only`. |

The stable process statuses are:

| Status | Category |
| ---: | --- |
| `0` | Clean review |
| `10` | Review-only completed with findings |
| `11` | Apply-fixes completed with findings |
| `12` | Incomplete review |
| `64` | Invalid invocation |
| `70` | Agent/backend failure |
| `77` | Write-boundary violation |

For precise meanings use the [exit status contract](exit-statuses.md). For
machine consumers, the [result-file contract](result-file.md) documents every
field, an example JSON object, and an outer LLM/Skill decision example.

State is scoped per target directory (see State Directory below), so pass
the required slot assignments and the same `<target_directory>` you reviewed
to `--status`/`--reset`/etc. to inspect or reset that project's history.

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
```

## State Directory

Each target directory you run against gets its own state folder under
`${XDG_STATE_HOME:-$HOME/.local/state}/adversarial-review/` (or
`AR_STATE_ROOT` when explicitly set), named from its basename plus a short hash of its full path (so
two differently-located folders that happen to share a name don't collide).
This stable root is independent of a source checkout or versioned Plugin install,
so Plugin upgrades preserve the same state and Artifacts.
This means:

- Reviewing project A and then project B never mixes their `tracking.json`
  history, artifacts, or circuit breaker counters.
- An OPEN circuit breaker (or a leftover `--dry-run`) from one project can't
  block or pollute a run against a different one.
- `--status`/`--reset`/`--circuit-status`/`--reset-circuit` all require the
  two slot assignments and target directory used to identify that project's
  state.

## Circuit Breaker

Prevents runaway loops by detecting:

- **No progress**: 3 iterations with no fixes made
- **Persistent disagreement**: 5+ iterations where agents can't agree
- **Same issues**: 3+ iterations finding the same unfixable issues

```bash
# Check circuit breaker status for a specific project
./adversarial_review.sh --circuit-status claude codex ../my-project

# Reset if stuck
./adversarial_review.sh --reset-circuit claude codex ../my-project
```

## Customization

### Custom Review Prompts

```bash
# Add review criteria for this run
./adversarial_review.sh -p my_review_prompt.md claude codex ../project
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
sandbox. With `--apply-fixes` (or the implicit default), only the agent
selected for Phase 4 receives write access. With `--review-only`, Phase 4
retains the read-only boundary and the target content and mtimes are checked
before and after synthesis.

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
1. **Both agents report NO_ISSUES** in Phase 1 (apply-fixes only;
   review-only continues through synthesis)
2. **Synthesis completes** with EXIT_SIGNAL: true
3. **Max iterations reached**
4. **Circuit breaker opens** (stagnation detected)

### Artifacts

Each iteration produces:
- `iter{N}_1_<backend>_review.md` - slot A's initial review
- `iter{N}_1_<backend>_review.md` - slot B's initial review
- `iter{N}_2_<backend>_on_<other_backend>.md` - cross-review
- `iter{N}_3_<backend>_meta.md` - meta-review
- `iter{N}_4_synthesis.md` - Final synthesis and fixes

`<backend>` is the actual `claude` or `codex` assignment, never the slot name.
Heterogeneous assignments retain the established paths. For a same-backend
pair, the unchanged filenames live under `artifacts/slot-a/` and
`artifacts/slot-b/` to prevent collisions.

Every agent reply has a companion `*.invocation.json` recording the phase,
backend, effective `execution_mode`, native enforcement mode, allowed tools,
and whether write access was actually authorized. Together,
`execution_mode` and `write_authorized` show why Phase 4 did or did not receive
write access. Review calls also retain structured `*.raw.log` events (Claude
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

## Repository-level Skill

### Local Plugin installation

The repo-local marketplace is declared at `.agents/plugins/marketplace.json`,
and its only entry points to `plugins/adversarial-review`. Register the
repository root with `codex plugin marketplace add`, list
`adversarial-review-local`, and install
`adversarial-review@adversarial-review-local`. Start a new thread so Codex
discovers the installed Skill. The package has no MCP server, connector, hook,
automation, or GitHub integration; it contains only the Skill, its display
metadata, references, stable launch Adapter, and matching CLI runtime with its
libraries and prompts.

For a Git-backed installation, register `longs-aegislo/adversarial-review` (or
its HTTPS/SSH URL) with `--ref <tag-or-commit>` to pin a known release. The
marketplace entry remains ordered in `plugins[]`, points at the packaged Plugin
root, and carries installation, authentication, product, and category policy.
Use `codex plugin list --available --json` to confirm the version and enabled
state. Upgrade a branch-tracking installation from this checkout with:

```bash
./scripts/upgrade-plugin.sh
```

The command first migrates pre-0.3 state from the installed version cache to
the stable user state root, refusing to overwrite a conflicting destination.
It then refreshes the snapshot and versioned install cache, replacing Skill, Adapter,
runtime, libraries, prompts, and compatibility metadata as one package; files
removed from the newer package are not overlaid from the old version. Target
Repo state and Artifacts live outside that installed package and remain intact.
The package's `compatibility.json` binds its manifest version to CLI result
schema 1, Skill workflow 1, and installation layout 1.

The repository ships `.agents/skills/adversarial-review` for post-implementation
or pre-commit/PR adversarial reviews. Invoke `$adversarial-review` explicitly,
or describe that goal clearly to use implicit discovery. Ordinary code
explanation, lightweight single-reviewer review, general debugging, and a
request only to publish a PR stay outside its trigger boundary. From the
trusted Target Repo, its adapter identifies that workspace, gives an explicit
baseline priority, uses `HEAD` for worktree-only changes, and uses a known local
default branch (`init.defaultBranch`, then `main`/`master`) for committed feature work (including mixed committed and
uncommitted changes). It selects heterogeneous `claude`/`codex` slots and
defaults to `review-only`. Only an explicit review-and-fix request selects
`apply-fixes`, and that path requires an explicit Fixer.

Inference stops before Agent calls for detached HEAD, shallow history, a local
branch whose default cannot be identified, or when only a missing or potentially
stale remote baseline is available. For a tracked feature branch, the local
default must match the corresponding remote-tracking default ref. Matching refs
may proceed and disclose that no fetch occurred; a missing or divergent remote
default stops with guidance to provide an explicit baseline or separately
authorize fetch/reconciliation. The adapter never fetches itself.

An installed Plugin Adapter always uses the runtime bundled under that same
Plugin root and rejects runtime overrides. A source-tree Skill resolves
`adversarial_review.sh` from an explicit override, then `PATH`, and finally the
root of its repository.

Before any real Agent call, the adapter prints the Target Repo, baseline,
reviewer slots, and mode. It first checks the CLI's required slot options, the
selected backend executables and authentication, `jq`, and CLI-compatible
`timeout` support.
Missing prerequisites stop the workflow without installation, credential
changes, or review calls. The default is heterogeneous `claude`/`codex`; an
explicit `claude`/`claude` or `codex`/`codex` request is allowed but reported as
lower-diversity same-model redundancy. It then runs a dry-run with those exact
values and starts the real review only after the documented output contains a
valid, non-empty, plausibly sized Review Scope. Empty, malformed, or more than
500 files is treated as unsafe and stops before the real review. Every previewed
path must also occur in the selected baseline's Git delta, so an accidental
whole-repository scope below that limit is rejected too. It accepts only result
schema version 1 and validates every required field, cross-field invariant, and
process/result exit status without falling back to terminal prose or tracking
state. It reports mode, scope/base, reviewer/Fixer assignments, termination
reason, iterations, scoped counts, modified files, verification, and
State/Synthesis/Artifacts paths. Clean, findings remaining, maximum iterations,
circuit open, invalid invocation, Agent/backend failure, and write-policy
violation receive distinct actionable explanations. After apply-fixes it lists both machine-result changed paths
and every path in the Target Repo Git diff, keeping unresolved findings
separate. The caller passes the highest relevant safe verification command
explicitly when repository documentation provides one. It passes the executable
and repeated arguments as structured argv and executes them directly without a
shell parser. Each supported tool has a fixed, bounded argument shape; trailing
arguments that could select a runner, shell, configuration, or collected file
are rejected before Agent calls. Otherwise the adapter reports that none was provided and never installs dependencies. Review
authorization never expands to commits, pushes, PR creation, fetch, reset,
clean, dependency installation, or modifying pre-existing findings.

Plugin installation intentionally does not provision Bash, `jq`, GNU-compatible
timeout support, Claude or Codex, authentication, subscriptions, model quota,
or network access. These are external runtime prerequisites. The installed
Adapter checks locally observable availability and authentication before Agent
startup; subscription validity, quota, and network failures remain backend
runtime conditions and are reported as Agent/backend failures. Its summary
keeps total Findings, scoped applied-Fix counts, and changed paths distinct.
It reports remaining Findings only from the stable termination category:
`none`, `present`, or `unknown` when the review did not complete.

An installed Plugin Adapter also defaults review state and Artifacts to
`${XDG_STATE_HOME:-$HOME/.local/state}/adversarial-review` instead of next to
the bundled runtime, so they are not deleted along with the Plugin's cache.
Uninstalling uses `codex plugin remove adversarial-review@adversarial-review-local`
(drops the installed Plugin and its Skill) and, separately,
`codex plugin marketplace remove adversarial-review-local` (drops the
marketplace registration so it no longer appears in
`codex plugin list --available`); neither command modifies a Target Repo or
its review state/Artifacts.

`tests/test_plugin_package.sh` uses an isolated `HOME` and `CODEX_HOME` to
register, list, and install the local marketplace, assert discovery of exactly
one Skill, then run that installed Skill Adapter through the bundled runtime
with fake Agent backends after making the marketplace source unavailable. It
verifies review-only and apply-fixes, including Phase 4-only write
authorization, changed-path and verification reporting, prerequisite failures,
and explicit same-model redundancy, without using model subscriptions, a
source-tree runtime, or a conflicting runtime on PATH. It also installs from a
marketplace source built under a simulated `core.autocrlf=true` (Windows/WSL
style) checkout and confirms the installed package bytes stay LF and the
installed Skill still launches, then removes the Plugin and its marketplace
and confirms both become undiscoverable while the Target Repo and review
state/Artifacts remain intact.
`tests/test_plugin_marketplace_lifecycle.sh` uses an offline SSH-backed Git
fixture to verify a pinned tag and a branch upgrade from 0.2.0 to 0.3.0. It
checks the listed/enabled version, complete Skill/runtime replacement, removal
of an old-only file, compatibility pairing, and preservation of Target Repo
review state and Artifacts.
When `codex` is unavailable, the package and containment assertions still run
and the CLI integration portion reports `SKIP`; release or acceptance jobs can
set `REQUIRE_CODEX_PLUGIN_TESTS=true` to require the real CLI path.

Deterministic scenarios in `tests/test_skill_scenarios.sh` exercise clean,
findings-remaining, authorized and ambiguous fix intent, modified-file
disclosure, verification present/absent, forbidden permission expansion,
baseline selection, ambiguous Git states, reviewer selection, prerequisite failures, unsafe scopes, and default CLI-discovery behavior with
fixture Target Repos and a fake CLI, without model calls or subscriptions.
They also preserve representative implicit post-implementation prompts and
near-miss explanation, lightweight review, debugging, and PR-publication
prompts, and assert that the Skill metadata describes those boundaries. Actual
implicit selection is host/model-dependent; the deterministic suite does not
claim to execute or verify the host's semantic router. Small authenticated
backend evaluations may provide usability evidence but are not acceptance
dependencies. The
main Skill stays compact; baseline examples, result interpretation, and common
preflight/compatibility remedies are loaded from its workflow reference only
when needed. The Skill is a CLI Adapter: it does not reproduce the four review
phases, tracking layout, or machine-result contract.

### Plugin release gate

Run `./scripts/validate-plugin-release.sh` from a candidate checkout. It first
validates the manifest identifier, semantic version, Plugin-relative paths,
root containment, marketplace identity, `compatibility.json`, and the matching
`docs/releases/<version>.md`, and requires square PNG `logo` and `composerIcon`
assets at Plugin-relative paths. It then uses the real Codex Plugin CLI to run
package plus Git lifecycle acceptance in disposable `HOME`/`CODEX_HOME`
profiles. Fake Claude/Codex backends exercise review-only and apply-fixes, so
the deterministic gate needs no subscriptions or paid model calls. A release
operator may separately run one small authenticated review-only/apply-fixes
smoke test; that is manual evidence, not an acceptance dependency.

For local development, rebuild by updating the source runtime and its bundled
copy together, bump the manifest and compatibility versions together, and add
`docs/releases/<version>.md`. Run `--metadata-only` for a fast check, then the
full gate. To test the actual installed shape, remove and re-add the local
marketplace (refreshing its cache), reinstall the Plugin, start a new Codex
thread for Skill discovery, and invoke `$adversarial-review` from a fixture
Target Repo. Use `upgrade-plugin.sh` instead when testing an upgrade because it
also covers legacy state migration.

Every release note must state external prerequisites, supported platforms,
host compatibility, result-schema version, migration/compatibility guidance,
and known limitations. A compatibility failure means the manifest version,
`compatibility.json`, release-note filename/fields, or installed Codex CLI does
not match the candidate; repair or deliberately update the contract rather
than bypassing the gate. Linux is automated, Windows is supported through WSL
and CRLF fixtures, and macOS depends on community/manual smoke evidence. The
Plugin API remains experimental, and public universal Plugin directory
submission is not part of this release process.

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
- Phase 1: 2 calls (slot A + slot B)
- Phase 2: 2 calls (slot A + slot B)
- Phase 3: 2 calls (slot A + slot B)
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
