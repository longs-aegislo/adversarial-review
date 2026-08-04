# Process Exit Statuses

`adversarial_review.sh` exposes the following stable process exit statuses.
Callers may rely on these values across internal refactors. Internal phase and
backend return values are mapped to this public contract before the process
exits and are intentionally not part of the interface.

| Status | Name | Meaning |
| ---: | --- | --- |
| `0` | clean | The review completed and no findings remain. This includes a clean Phase 1 and a clean synthesis. Management commands also retain their existing success status of `0`. |
| `10` | review-only-findings | A `--review-only` run completed synthesis and reported one or more unresolved findings. |
| `11` | apply-fixes-findings | An `--apply-fixes` run completed its permitted fixes, but one or more findings remain unresolved or were reported as pre-existing. |
| `12` | incomplete-review | The review did not complete because it reached `--max-iters` or the circuit breaker opened. The log and `tracking.json` status distinguish `max_iterations` from `circuit_open`. |
| `64` | invalid-invocation | The invocation was rejected before any Agent call, for example because arguments conflict, a base ref is invalid, or required input is missing. |
| `70` | agent-backend-failure | A required Agent/backend is unavailable or failed, timed out, or returned a malformed required response. |
| `77` | write-boundary-violation | A read-only Agent attempted a denied write, or the target changed during a read-only phase. |

`--review-only` and `--apply-fixes` share this contract. Only their completed
findings statuses differ (`10` and `11`) so automation can tell whether changes
may already have been applied. `--status`, `--reset`, `--circuit-status`, and
`--reset-circuit` keep their established command semantics.
