# Reviewer slots get a breaking positional CLI contract, not an additive flag

`--base` (see issue #1) set a precedent: new capabilities are additive, so
unset flags reproduce today's behavior exactly. The reviewer-slot design
(configurable backend per review position, `--slot-a`/`--slot-b`) breaks that
precedent on purpose: `slot-a`/`slot-b`/`target_dir` become positional
arguments with no defaults, so `./adversarial_review.sh ../my-project` (today's
single-positional invocation) is rejected rather than silently reinterpreted.

We chose this because `target_dir` moves from the only positional argument to
the third of three, and letting `../my-project` silently land in `slot-a`'s
position when a caller forgets the new arguments would misconfigure which
agent reviews what without any error — a worse failure mode than requiring
existing callers to update their invocation once. Every positional also gets
an equivalent long flag (`--slot-a`, `--slot-b`, `--target-dir`), so callers
who want no ambiguity can opt out of positional args entirely.

## Considered Options

- Keep `target_dir` as the sole positional and require `--slot-a`/`--slot-b`
  as flags only. Rejected: it doesn't give the terser positional shorthand the
  reviewer slot design was asked to provide.
- Make positional argument count adaptive (1 positional = `target_dir` only,
  3 = `slot-a slot-b target_dir`) to preserve the old single-positional form.
  Rejected: ambiguous and easy to misread when exactly 2 positionals are
  passed by mistake.

## Consequences

Any external automation invoking `adversarial_review.sh <target_dir>` as a
single positional argument breaks and must add `slot-a slot-b` positionals or
switch to `--target-dir`.
