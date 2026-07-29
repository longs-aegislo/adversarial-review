# Issue Tracker

This repo tracks work in **GitHub Issues** (`origin` → `github.com/longs-aegislo/adversarial-review`), via the `gh` CLI.

- `to-spec`, `to-tickets`, `triage`, and `qa` read from and write to GitHub Issues.
- Specs are published with `gh issue create` and labeled per `docs/agents/triage-labels.md` conventions (only `ready-for-agent` is in active use — the `triage` skill itself isn't installed in this repo).
- PRs-as-a-request-surface: **off**. Incoming PRs are not treated as triage-queue items.
