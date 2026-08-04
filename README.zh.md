[English](README.md) | **中文** | [日本語](README.ja.md)

# Adversarial Review（对抗式代码审查）

基于 Claude 与 GPT Codex 对抗式辩论循环的多智能体代码审查工具。

灵感来自 [asimov-ralph](https://github.com/frankbria/ralph-claude-code)
以及 [AI Debate](https://arxiv.org/abs/2410.04663) 相关研究。

## 核心理念

Claude 和 Codex 各自独立审查目标项目，互相质疑对方的发现，调解分歧，
最后由选定的修复智能体实施双方认可的修改。

整个循环分为四个阶段：

1. 独立审查
2. 交叉审查
3. 元审查与共识
4. 综合与修复

每条发现都会标记为 `IN_SCOPE` 或 `PRE_EXISTING`。在 apply-fixes 模式下，
阶段四默认只修复 `IN_SCOPE`，并单独报告历史问题。只有明确希望同时修复两类
问题时，才传入 `--include-pre-existing`。

阶段一至阶段三使用只读智能体权限；只有 apply-fixes 模式会给阶段四中选定的
Fixer 写权限。`--prompt FILE` 只为本次运行追加阶段一审查标准，不会替换强制的
Issue、Scope 或 Status 协议。

传入 `--review-only` 或 `--apply-fixes` 以显式声明本次调用是希望阶段四
执行只读综合，还是获得写权限并应用修复。在 review-only 模式下，四个阶段
仍会完整运行；阶段四复用阶段一至三的只读 Backend 边界，并分别列出尚未解决的
`IN_SCOPE` 与 `PRE_EXISTING` findings，不修改 Target Repo。两者互斥，且会在
任何依赖检查或 Agent 调用之前完成校验。两者都省略时，行为仍与当前隐式的
apply-fixes 一致，并打印迁移提示。新增的自动化、Skill、Plugin 应当显式传入
其中一个 flag。

每次调用现在都必须明确提供两个审查槽位和目标目录：
`slot-a slot-b target-dir`。三者都可以改用对应的长选项。槽位接受
`claude` 或 `codex`；两个槽位使用同一后端时仍可运行，但会提示审查多样性降低。

## 快速开始

```bash
cd adversarial-review

# 审查一个项目
./adversarial_review.sh claude codex ../my-project

# 只审查相对某个 Git ref 的变更
./adversarial_review.sh --base main claude codex ../my-project

# 选择阶段四的修复智能体
./adversarial_review.sh --fixer codex claude codex ../my-project

# 为本次运行追加审查标准
./adversarial_review.sh --prompt security-review.md claude codex ../my-project

# 为 CI 或其他自动化原子写入 JSON 结果
./adversarial_review.sh --apply-fixes --result-file review-result.json claude codex ../my-project

# 不调用 API，预览范围与阶段四策略
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## 依赖要求

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）或 `apt install jq`（Linux）
- **coreutils**（仅 macOS，用于 timeout）：`brew install coreutils`

## 文档

- [详细指南](docs/guide.zh.md)——完整 CLI、审查阶段、状态管理、产出文件、
  自定义方式与成本说明
- [进程退出状态](docs/exit-statuses.zh.md)——供 CI 与其他自动化使用的稳定状态契约
- [机器可读结果文件](docs/result-file.zh.md)——覆盖每条终止路径的版本化原子 JSON
- [Fork 变更记录](docs/fork-notes.zh.md)——相对上游的修改与修复
- [领域术语表](CONTEXT.md)——实现中使用的统一术语
- [工具对比评测](docs/evaluations/tool-bakeoff/README.md)——与 Chorus、
  Open Code Review、coding-review-agent-loop 的比较，包含可复现 fixture 与原始证据

## 参与贡献

这是一个实验性原型。可继续改进的方向包括增加审查智能体、基于准确率的投票、
成本控制，以及更好的产出文件可视化。

## 许可证

MIT
