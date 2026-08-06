# 机器可读结果文件

传入 `--result-file <路径>` 后，每次调用都会以原子方式用一个完整 JSON 对象替换
该路径。只有参数解析实际读到该选项后，目的地才生效；此后无论正常完成还是沿任一
失败路径退出，都会生成结果。既有终端输出保持不变。

对于 Git 工作树，`target_changes.files` 覆盖已跟踪文件和未被忽略的未跟踪文件，
不包含 Git 已忽略文件。`target_repo.identity` 和 `target_repo.remote_url` 会移除
URL 用户信息，避免把远程地址中嵌入的凭据写入结果产物。

```bash
./adversarial_review.sh --apply-fixes --result-file review-result.json \
  claude codex ../my-project
```

写入器先在目的地旁创建临时文件，完整写完后再 rename。读取方因此只会看到旧的
完整结果或新的完整结果，不会观察到半份 JSON。

## Schema 版本 1

公开 Schema 的全部字段如下。取不到值或对应阶段未运行时，可空字符串字段为 JSON
`null`。

- `schema_version`（整数）：当前为 `1`。
- `target_repo`（对象）：`identity`（优先为远程 URL，否则为 Target 绝对路径）、
  `path`（Target 绝对路径）、可空 `git_root`、已移除凭据的可空 `remote_url`，以及
  可空的运行起始 `head_commit`。
- `reviewers`（对象）：可空的已解析 `slot_a`、`slot_b` Backend。
- `synthesis`（对象）：可空 `requested_fixer` 与可空 `executed_by`；后者表示实际
  执行阶段四的 Agent。
- `scope`（对象）：`kind`（`whole-directory` 或 `base`）、可空
  `requested_base_ref` 与可空 `resolved_base_commit`。
- `execution`（对象）：`mode`（`review-only` 或 `apply-fixes`）、布尔值
  `dry_run`、布尔值 `review_executed` 与布尔值 `include_pre_existing`。
- `termination`（对象）：稳定 `category`、更具体的 `reason` 与数字 `exit_code`；
  分类与[退出状态契约](exit-statuses.zh.md)一致。
- `iterations`（整数）：本次调用进入的迭代次数。
- `counts.findings`（对象）：去重后的 `in_scope`、`pre_existing` finding 数与
  `scope_conflicts`；scope 有分歧时会保守地同时计入后两者。
- `counts.fixes`（对象）：`in_scope` 与 `pre_existing` 修复数。
- `counts.pre_existing_flagged`（整数）：Synthesis 已报告但未修复的历史 finding 数。
- `target_changes`（对象）：布尔值 `modified` 与 `files`；后者列出相对 Target
  被修改、新建或删除的路径。
- `paths`（对象）：`state_dir`、`artifacts_dir` 与可空
  `final_synthesis_artifact` 路径。

示例（路径、commit ID 与计数仅用于说明）：

```json
{
  "schema_version": 1,
  "target_repo": {
    "identity": "https://github.com/example/shop.git",
    "path": "/work/shop",
    "git_root": "/work/shop",
    "remote_url": "https://github.com/example/shop.git",
    "head_commit": "0123456789abcdef0123456789abcdef01234567"
  },
  "reviewers": { "slot_a": "claude", "slot_b": "codex" },
  "synthesis": { "requested_fixer": "codex", "executed_by": "codex" },
  "scope": {
    "kind": "base",
    "requested_base_ref": "main",
    "resolved_base_commit": "fedcba9876543210fedcba9876543210fedcba98"
  },
  "execution": {
    "mode": "review-only",
    "dry_run": false,
    "review_executed": true,
    "include_pre_existing": false
  },
  "termination": {
    "category": "review-only-findings-remain",
    "reason": "review-only-findings-remain",
    "exit_code": 10
  },
  "iterations": 1,
  "counts": {
    "findings": { "in_scope": 2, "pre_existing": 1, "scope_conflicts": 0 },
    "fixes": { "in_scope": 0, "pre_existing": 0 },
    "pre_existing_flagged": 1
  },
  "target_changes": { "modified": false, "files": [] },
  "paths": {
    "state_dir": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4",
    "artifacts_dir": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4/artifacts",
    "final_synthesis_artifact": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4/artifacts/iter1_4_synthesis.md"
  }
}
```

`--dry-run` 会保留所选执行模式，但将 `dry_run` 设为 `true`、
`review_executed` 设为 `false`、`synthesis.executed_by` 设为 `null`。其正常的
最大迭代结果仍为 `incomplete-review`，不会被误读为真实审查已经完成。
它与 `--review-only` 不同：dry-run 不调用 Agent，也不产生审查结论，因此不能替代
只读审查。

## 供外层 LLM 或 Skill 消费

编排用 LLM/Skill 应读取 JSON 字段，而不是解析终端文本。例如：若
`execution.review_executed` 为 false，则报告本次没有发生审查；若
`termination.category` 为 `review-only-findings-remain`，则打开
`paths.final_synthesis_artifact`，询问人类是否启动一次新的、显式的
`--apply-fixes` 运行；若分类为 `clean`，则继续发布。其余分类都应视为流程中止或
失败，并展示 `termination.reason`。不能仅因 JSON 文件存在就推断成功。

所有值都来自人类可读工作流同源的已解析 status block、tracking state、CLI
解析结果与 Target 快照；结果写入器不会重新解析终端文本。

目的地无法被原子替换时（例如该路径是目录），脚本会保留审查本身的退出码，并向
stderr 明确报告写入失败；持久化失败不会被静默忽略。
