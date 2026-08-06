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

## 自动化契约

| 模式 | Agent 调用 | Target 写入 | 完成但仍有 findings 的状态 |
| --- | --- | --- | ---: |
| `--review-only` | 完整四阶段 | 绝不写入 | `10` |
| `--apply-fixes` | 审查阶段及获准的修复／验证工作 | 阶段四可写入 | `11` |
| 两者都不传（旧行为） | 与 `--apply-fixes` 相同 | 阶段四可写入 | `11` |

旧隐式模式会打印迁移提示，未来可能移除；新增自动化必须显式选择模式。
`--dry-run` 只做预览：它不调用 Agent，也不产生审查结论，因此不能替代
`--review-only`。

稳定退出状态为：`0` 无问题、`10` review-only 仍有 findings、`11` apply-fixes
仍有 findings、`12` 审查未完成、`64` 调用无效、`70` Agent/Backend 失败、`77`
写入边界违规。增加 `--result-file PATH` 可获得完整的版本化 JSON 结果；
[结果文件契约](docs/result-file.zh.md)包含全部字段、示例对象及外层 LLM/Skill 的
路由指引。

## 依赖要求

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）或 `apt install jq`（Linux）
- **coreutils**（仅 macOS，用于 timeout）：`brew install coreutils`

## 作为本地 Codex Plugin 安装

本仓库也是一个自包含的本地 marketplace。可在隔离或普通 Codex profile 中注册当前
checkout 并安装 Plugin：

```bash
codex plugin marketplace add /absolute/path/to/adversarial-review
codex plugin list --marketplace adversarial-review-local --available
codex plugin add adversarial-review@adversarial-review-local
```

如需可复现的 Git-backed 安装，将本地路径替换为
`longs-aegislo/adversarial-review`，并用 `--ref <tag-or-commit>` 固定版本。
通过 `codex plugin list --available --json` 确认所选版本。若跟踪某个分支，在此 checkout
运行 `./scripts/upgrade-plugin.sh`。它会先把 0.3 之前的 state 迁出旧版本安装，再刷新
marketplace 并重装完整 package，同时保持 Target Repo review state 与 Artifacts 不变。
从 0.3 之前的安装升级时，不要用直接 `plugin add` 代替此命令。

安装后启动新的 Codex 对话，并在 Target Repo 中调用 `$adversarial-review`。安装单元只
包含一个 Skill，以及匹配版本的 CLI runtime、库、Prompt 和参考资料；不依赖本源码
checkout 或个人 Skill 安装。默认使用 `review-only`，只有显式 `apply-fixes` 请求才可能
授权修改 Target Repo。`compatibility.json` 将 Plugin 版本绑定到共同测试过的 CLI result
schema、Skill workflow 和安装 layout。
方形 logo 与 composer icon 随 Plugin 一起打包，并通过相对 Plugin root 的 manifest 路径
声明，以保证 directory 展示一致。

Plugin 安装不会安装或配置 Bash、`jq`、timeout 支持、Agent backend、认证、订阅、
模型配额或网络访问。这些均是外部前置条件，只在 Skill 调用时、任何审查 Agent 启动前
检查。只有一个 backend 可用时仍可安装；仅当两个 reviewer slots 都显式选择该 backend
时才能运行，Adapter 会将其报告为审查多样性较低的 same-model redundancy。

已安装 Plugin 运行的 review state 和 Artifacts 保存在
`${XDG_STATE_HOME:-$HOME/.local/state}/adversarial-review`，而非安装包内部，
因此升级或卸载都不会丢失。

维护者使用 `./scripts/validate-plugin-release.sh` 验证候选版本。门禁检查稳定
identifier、语义版本、host/platform compatibility、包边界、Skill discovery、两种执行
模式、Git 固定/升级和 clean profile 卸载；全程只使用 fake backend，不调用付费模型。
本地 rebuild 循环、兼容性排错、release notes 和可选真实 backend smoke test 见
[详细指南](docs/guide.zh.md#plugin-发布门禁)。公共 universal Plugin directory 投稿仍不在范围内。

### 卸载

```bash
codex plugin remove adversarial-review@adversarial-review-local
codex plugin marketplace remove adversarial-review-local
```

第一条命令移除已安装的 Plugin 及其 Skill；第二条命令还会移除本地 marketplace
source 的注册，使其不再出现在 `codex plugin list --available` 中。两条命令
均不会影响 Target Repo 文件或上述 review state/Artifacts。

## 文档

- [仓库级 Adversarial Review Skill](.agents/skills/adversarial-review/SKILL.md)——
  可通过显式调用，或明确的实现后对抗式审查、commit/PR 前复核请求隐式发现，且默认 review-only；仅在明确 review-and-fix 请求并指定 Fixer 时应用修复；先只读预检 CLI、backend、认证和依赖，再预览
  安全推断或接受 baseline、预览受保护的文件 scope、启动 Agent，最后严格校验版本化机器结果，
  并分别给出 clean、findings、未完成、策略违规和基础设施故障的可行动说明。普通代码解释、轻量单 reviewer 审查、一般调试和仅发布 PR 的请求不会触发；Skill 始终是 CLI 的薄 Adapter
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
