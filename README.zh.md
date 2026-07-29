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

每条发现都会标记为 `IN_SCOPE` 或 `PRE_EXISTING`。阶段四默认只修复
`IN_SCOPE`，并单独报告历史问题。只有明确希望同时修复两类问题时，才传入
`--include-pre-existing`。

## 快速开始

```bash
cd adversarial-review

# 审查一个项目
./adversarial_review.sh ../my-project

# 只审查相对某个 Git ref 的变更
./adversarial_review.sh --base main ../my-project

# 选择阶段四的修复智能体
./adversarial_review.sh --fixer codex ../my-project

# 不调用 API，预览范围与阶段四策略
./adversarial_review.sh --dry-run --base main ../my-project
```

## 依赖要求

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）或 `apt install jq`（Linux）
- **coreutils**（仅 macOS，用于 timeout）：`brew install coreutils`

## 文档

- [详细指南](docs/guide.zh.md)——完整 CLI、审查阶段、状态管理、产出文件、
  自定义方式与成本说明
- [Fork 变更记录](docs/fork-notes.zh.md)——相对上游的修改与修复
- [领域术语表](CONTEXT.md)——实现中使用的统一术语

## 参与贡献

这是一个实验性原型。可继续改进的方向包括增加审查智能体、基于准确率的投票、
成本控制，以及更好的产出文件可视化。

## 许可证

MIT
