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

顶层对象包含：

- `schema_version`：当前为 `1`。
- `target_repo`：Target Repo 身份、绝对路径、Git 根目录、`origin` URL，以及可用时
  的运行起始 `HEAD` commit。
- `reviewers`：解析后的 `slot_a`、`slot_b` Backend 分配。
- `synthesis`：请求的 fixer，以及实际执行阶段四的 Agent；阶段四未运行时
  `executed_by` 为 `null`。
- `scope`：`whole-directory` 或 `base`，以及请求的 base ref 与解析后的 commit。
- `execution`：`review-only`/`apply-fixes`、`dry_run`、是否实际执行过审查 Agent，
  以及 pre-existing finding 策略。
- `termination`：稳定退出分类、更具体的原因和进程退出码；分类与
  [退出状态契约](exit-statuses.zh.md)一致。
- `iterations`：本次调用进入的迭代次数。
- `counts`：来自已解析 status ledger 的去重 `IN_SCOPE`/`PRE_EXISTING` finding 数，
  scope 冲突数，以及来自已解析 Synthesis status 的修复数和仅标记的历史问题数。
  两份 reviewer ledger 对 scope 意见不一致时，会保守计入 `PRE_EXISTING`，同时计入
  `scope_conflicts`。
- `target_changes`：本次调用是否修改 Target，以及被修改、新建或删除的相对文件路径。
- `paths`：状态目录、Artifact 目录，以及存在时的最终 Synthesis Artifact。

`--dry-run` 会保留所选执行模式，但将 `dry_run` 设为 `true`、
`review_executed` 设为 `false`、`synthesis.executed_by` 设为 `null`。其正常的
最大迭代结果仍为 `incomplete-review`，不会被误读为真实审查已经完成。

所有值都来自人类可读工作流同源的已解析 status block、tracking state、CLI
解析结果与 Target 快照；结果写入器不会重新解析终端文本。

目的地无法被原子替换时（例如该路径是目录），脚本会保留审查本身的退出码，并向
stderr 明确报告写入失败；持久化失败不会被静默忽略。
