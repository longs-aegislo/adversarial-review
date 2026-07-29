**English** | [中文](fork-notes.zh.md) | [日本語](fork-notes.ja.md)

# Fork Notes

[Back to README](../README.md) · [Detailed guide](guide.md)

This repo is a fork of
[alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review)
(kept as the `upstream` remote). Since forking, this fork has fixed a number
of bugs found by running the tool against a real Laravel project and has
diverged from upstream in these ways:

- **Fixed `codex` invocation**: the original `run_codex()` used a stale CLI syntax (`-q --full-auto --prompt`) that no longer matches the current `codex` CLI. It now uses `codex exec -s <sandbox_mode> --skip-git-repo-check` with the prompt piped via stdin instead of passed as a positional argument (which was hitting `ARG_MAX`/ `timeout: Argument list too long` on large prompts).
- **Fixed source collection for non-JS/Python stacks**: `collect_source_code`/`collect_file_list` didn't exclude `vendor/`, `public/`, `storage/`, `bootstrap/cache/`, `dist/`, or `build/`, and had no PHP/Blade support - so on a Laravel project it was stuffing third-party vendored/minified JS into the prompt instead of the project's own source, which also blew past Claude's context limit.
- **Fixed Phase 3 losing the other agent's findings**: the meta-review prompt only re-supplied the feedback the other agent gave back, not that agent's original Phase 1 findings or your own Phase 2 cross-review of them. Since every phase is a fresh, stateless CLI call with no memory of earlier phases, this silently dropped one agent's entire set of findings from the final consensus. `run_phase_3()` now reconstructs full context for both agents.
- **Fixed `parse_status_block`'s "last block" extraction**: it used to concatenate every occurrence of a `---STATUS---...---END_STATUS---` marker pair in the text (including the prompt template's own baked-in EXAMPLE blocks), producing garbled/duplicate JSON. It's now an awk-based scanner that keeps only the last real block.
- **Added `-f/--fixer`**: lets you choose whether Claude or Codex implements Phase 4 fixes (interactively on a TTY, or via flag/env var), so you can route the most expensive step to whichever agent has more quota.
- **Added finding scope gates**: every finding is tagged `IN_SCOPE` or `PRE_EXISTING`, scope disagreements are reconciled during meta-review, and Phase 4 fixes only in-scope findings by default. Historical issues remain visible without being mixed into the synthesis changes; `--include-pre-existing` explicitly opts into fixing both categories.
- **Reworked Phase 1 to stop inlining full file contents**: agents now get a file path list (plus a `git diff` against `HEAD` from the second iteration onward) and read whatever files they need themselves, instead of having the whole codebase pasted into the prompt - see the Cost Considerations section in the detailed guide.
- **Added per-phase issue summaries to terminal output**: each phase now prints the agents' one-line summaries, not just issue counts.
- **Scoped all state per target directory**: `tracking.json`, the circuit breaker, and `artifacts/` used to live at the repo root and were shared across every target you ever ran against - review a second project and its Phase 1 findings could land next to (or trip a circuit breaker left over from) the first one's runs. State now lives under `state/<slug>/`, keyed by the target directory's path, so projects can't cross-contaminate each other's history.
- **Fixed Phase 2/3 running in the wrong directory**: after Phase 1 was reworked to stop inlining file contents, Phase 2 (`run_phase_2()`) and Phase 3 (`run_phase_3()`) still never passed `target_dir` to `run_claude`/`run_codex`, so both agents defaulted to the caller's working directory instead of the project being reviewed. Both phases now pass `target_dir` through; Claude receives read/search tools plus read-only `git log`/`git blame` access for scope classification.
- **Fixed unfiltered untracked-file dump in `collect_recent_diff()`**: it copied every untracked, non-ignored file into the prompt with no path, extension, or size filtering - a path for leaking unignored secrets or ingesting large/binary files. It now applies the source-collection exclusions, skips common secret-like filenames and binary files, and caps each file's contents.
- **Fixed a misleading diff label**: the Phase 1 diff section was labeled "changes since the last review iteration," but since this tool never commits between iterations, it is the cumulative uncommitted diff across the whole run. The label and surrounding prompt text now say so explicitly.
- **Fixed colliding issue IDs between agents**: both agents numbered findings from `ISSUE-1`, so Claude's and Codex's IDs became indistinguishable after merging. Each agent now prefixes IDs with its agent tag (`CLAUDE-1`, `CODEX-1`, ...).
- **Fixed Phase 2 additional findings being dropped from synthesis**: cross-review findings had no ID scheme and were not covered by the synthesis ledger. They are now tagged `{AGENT}-ADD-N`, and the Step 0 ledger explicitly enumerates them alongside Phase 1 findings.
