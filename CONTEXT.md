# Domain Glossary

- **Target directory / target repo** — the external project being reviewed (passed as the positional arg to `adversarial_review.sh`), as distinct from this tool's own repo.
- **Agent** — one of the two reviewing CLIs: **Claude** (`claude --print`) or **Codex** (`codex exec`). Each runs as a stateless, fresh process per phase call — no memory of earlier phases except what's re-supplied in the prompt.
- **Iteration** — one full pass through Phases 1-4 against the target directory. Bounded by `--max-iterations` (default 3).
- **Phase 1 (Independent Reviews)** — Claude and Codex each review the target directory's file list (+ diff since the last iteration) in parallel, blind to each other's findings.
- **Phase 2 (Cross-Review)** — each agent reviews the *other* agent's Phase 1 findings.
- **Phase 3 (Meta-Review)** — each agent responds to the feedback it received in Phase 2, with its own Phase 1 review, the other's Phase 1 review, and its own Phase 2 verdict all re-supplied (agents are stateless between phases).
- **Phase 4 (Synthesis)** — one agent (the "fixer", `claude` or `codex`, chosen via `--fixer`) synthesizes the full review chain and implements fixes directly in the target directory's working tree.
- **Consensus** — agreement between Claude and Codex that an issue is real, reached (or not) by the end of Phase 3; tracked via each phase's structured status block.
- **Status block** — a fenced key/value block every agent response must end with (e.g. `---REVIEW_STATUS---` / `---META_REVIEW_STATUS---` / `---SYNTHESIS_STATUS---`), parsed by `lib/response_analyzer.sh` to drive loop control.
- **EXIT_SIGNAL** — a status-block field; `true` means "no more issues," which can end the loop early.
- **Circuit breaker** (`lib/circuit_breaker.sh`) — stops the loop on stagnation: no progress after N iterations, persistent disagreement, or the same issues recurring.
- **Artifacts** — every agent response, saved under `artifacts/iter{N}_{phase}_{agent}_{type}.md` (see CLAUDE.md's Artifacts Naming Convention).
- **Raw transcript / `.raw.log`** — Codex's full `codex exec` stdout (reasoning summaries, tool calls, file dumps), saved alongside the extracted final-reply `.md` artifact but never fed into later prompts.
- **Fixer** — the agent (`claude` or `codex`) chosen to implement fixes in Phase 4.
- **Scope** — the boundary of source files Phase 1 is meant to review. By
  default this is every reviewable file in the target directory. With an
  explicit `--base <ref>`, it is instead the reviewable committed,
  uncommitted, and untracked files that differ from that Git ref; the same
  scope is retained across later iterations and recorded in run state.
