# 进程退出状态

`adversarial_review.sh` 对外提供以下稳定的进程退出状态。调用方可以跨内部重构
依赖这些数值。内部阶段与 Backend 返回值会在进程退出前映射到这份公开契约，且
刻意不属于对外接口。

| 状态 | 名称 | 含义 |
| ---: | --- | --- |
| `0` | clean | 审查已完成且没有剩余 findings，包括 Phase 1 直接通过和综合后通过。管理命令成功时也继续返回 `0`。 |
| `10` | review-only-findings | `--review-only` 已完成综合，并报告了一个或多个未解决 findings。 |
| `11` | apply-fixes-findings | `--apply-fixes` 已完成允许的修复，但仍有未解决 findings，或有 findings 被报告为 pre-existing。 |
| `12` | incomplete-review | 审查因达到 `--max-iters` 或 circuit breaker 打开而未完成。日志和 `tracking.json` 的状态会用 `max_iterations` 与 `circuit_open` 区分原因。 |
| `64` | invalid-invocation | 在任何 Agent 调用前拒绝了非法调用，例如参数冲突、base ref 无效或缺少必要输入。 |
| `70` | agent-backend-failure | 必要的 Agent/backend 不可用、执行失败、超时，或没有返回格式正确的必要响应。 |
| `77` | write-boundary-violation | 只读 Agent 尝试了被拒绝的写入，或 Target 在只读阶段发生变化。 |

`--review-only` 与 `--apply-fixes` 复用同一契约。只有完成后仍有 findings 的状态
分别使用 `10` 和 `11`，使自动化能够判断是否可能已经应用过修改。
`--status`、`--reset`、`--circuit-status` 与 `--reset-circuit` 保持原有命令语义。
