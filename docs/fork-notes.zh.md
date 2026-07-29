[English](fork-notes.md) | **中文** | [日本語](fork-notes.ja.md)

# Fork 变更记录

[返回 README](../README.zh.md) · [详细指南](guide.zh.md)

本仓库 fork 自
[alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review)
（原仓库保留为 `upstream` remote）。Fork 之后，我们用一个真实的 Laravel
项目实际运行这个工具，修复了不少问题，与上游的主要差异如下：

- **修复了 `codex` 调用方式**：原来的 `run_codex()` 使用已经不匹配当前 `codex` CLI 的旧语法（`-q --full-auto --prompt`）。现在改为 `codex exec -s <sandbox_mode> --skip-git-repo-check`，并通过 stdin 传入 prompt，避免大 prompt 触发 `ARG_MAX` / `timeout: Argument list too long`。
- **修复了非 JS/Python 技术栈的源码收集逻辑**：原来的源码收集没有排除 `vendor/`、`public/`、`storage/`、`bootstrap/cache/`、`dist/`、`build/`，也不支持 PHP/Blade，导致 Laravel 项目把第三方压缩依赖而非项目源码塞入 prompt。
- **修复了阶段三丢失对方发现的问题**：元审查曾只重新提供对方反馈，没有提供对方阶段一的原始发现和自己阶段二的交叉审查。由于每个阶段都是无记忆的独立 CLI 调用，这会静默丢失一方的发现；现在 `run_phase_3()` 会重建完整上下文。
- **修复了 `parse_status_block` 的“取最后一块”逻辑**：旧实现会拼接所有状态块标记，包括 prompt 模板中的示例，产生错乱 JSON；现在使用 awk 扫描并只保留最后一个真实状态块。
- **新增 `-f/--fixer`**：可以选择由 Claude 还是 Codex 实施阶段四修复，把最昂贵的步骤交给额度更充裕的智能体。
- **新增发现范围门控**：每条发现都标记为 `IN_SCOPE` 或 `PRE_EXISTING`，元审查会调解范围分歧；阶段四默认只修复当前范围内的问题，`--include-pre-existing` 可显式选择同时修复历史问题。
- **重构阶段一，不再内联完整文件内容**：智能体只获取文件路径列表（第二轮起还会附上相对 `HEAD` 的 `git diff`），需要时自行读取文件。
- **在终端输出中加入每个阶段的问题摘要**：现在每个阶段会打印智能体的一句话摘要，而不只是问题数量。
- **按目标目录隔离所有状态**：`tracking.json`、断路器和 `artifacts/` 现在位于 `state/<slug>/`，不同项目的历史不会互相污染。
- **修复阶段二/三运行在错误目录的问题**：两个阶段现在都会传入正确的 `target_dir`；Claude 除读取／搜索工具外，还能以只读方式执行 `git log`/`git blame` 来判断发现范围。
- **修复 `collect_recent_diff()` 中未过滤的未跟踪文件转储**：现在应用源码收集的路径规则，跳过常见密钥文件名和二进制文件，并限制单个文件内容大小。
- **修复误导性的 diff 标签**：阶段一现在明确说明显示的是整次运行累计的未提交 diff，而不是仅自上一轮以来的变更。
- **修复双方发现编号冲突**：每个智能体现在使用带身份前缀的 ID（`CLAUDE-1`、`CODEX-1` 等）。
- **修复阶段二新增发现从综合阶段静默丢失的问题**：交叉审查发现现在使用 `{智能体}-ADD-N`，并进入综合阶段的完整 ledger。
