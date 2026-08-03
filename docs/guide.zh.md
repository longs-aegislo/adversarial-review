[English](guide.md) | **中文** | [日本語](guide.ja.md)

# Adversarial Review 详细指南

[返回 README](../README.zh.md) · [Fork 变更记录](fork-notes.zh.md)

基于 Claude 与 GPT Codex 对抗式辩论循环的多智能体代码审查工具。

灵感来自 [asimov-ralph](https://github.com/frankbria/ralph-claude-code) 以及 [AI Debate](https://arxiv.org/abs/2410.04663) 相关研究。

## 关于本 Fork

本 fork 相对上游的全部修改记录单独维护在
[Fork 变更记录](fork-notes.zh.md)中。

## 核心理念

两个可配置的审查槽位分别由 Claude 或 Codex 后端执行，各自独立审查代码，
再通过多轮辩论互相批判对方的发现。两个槽位可使用不同或相同的后端。这种对抗式流程有助于：

- **发现更多问题**：不同模型能捕捉到不同的问题
- **消除误报**：交叉验证能过滤掉不正确的发现
- **达成共识**：分歧通过结构化辩论来解决
- **提升置信度**：双方都认同的问题是高置信度的待修复项

## 四阶段循环

```
┌─────────────────────────────────────────────────────────────┐
│  阶段一：独立审查                                             │
│    槽位 A 审查代码 → <backend>_review.md                     │
│    槽位 B 审查代码 → <backend>_review.md                     │
│    两个智能体只拿到一份文件路径清单（从第二轮起还会附上         │
│    自上一轮以来的 git diff），需要用自己的工具去读取想看的     │
│    文件——不再把整个代码库的文件内容直接塞进 prompt             │
│    （并行执行）                                               │
├─────────────────────────────────────────────────────────────┤
│  阶段二：交叉审查                                             │
│    槽位 A 审查槽位 B 的发现                                   │
│    槽位 B 审查槽位 A 的发现                                   │
│    （并行执行）                                               │
├─────────────────────────────────────────────────────────────┤
│  阶段三：元审查（Meta-Review）                                │
│    槽位 A 回应槽位 B 的批评                                   │
│    槽位 B 回应槽位 A 的批评                                   │
│    每个智能体都会拿到：自己第一阶段的审查结果、对方第一阶段的  │
│    审查结果、自己在第二阶段对对方发现的交叉审查，以及自己收到  │
│    的反馈——每次都是完整上下文，避免发现在共识阶段悄悄消失      │
│    （并行执行）                                               │
├─────────────────────────────────────────────────────────────┤
│  阶段四：综合与修复                                           │
│    由 Claude 或 Codex（通过 --fixer 选择）审阅全部辩论记录，   │
│    默认只修复 IN_SCOPE 问题；PRE_EXISTING 问题只单独报告，     │
│    除非显式传入 --include-pre-existing                         │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              回到阶段一验证修复效果，
              直到双方都报告 NO_ISSUES（无问题）
```

## 快速开始

```bash
# 克隆或复制到你的工作目录
cd adversarial-review

# 对目标项目运行（若 stdin 是交互终端，会询问由哪个智能体
# 负责阶段四的修复实现）
./adversarial_review.sh claude codex ../my-project

# 带选项运行
./adversarial_review.sh -m 5 -v claude codex ../my-project
./adversarial_review.sh -f codex claude codex ../my-project
./adversarial_review.sh -f claude claude codex ../my-project
./adversarial_review.sh --base main claude codex ../my-project
./adversarial_review.sh --include-pre-existing claude codex ../my-project

# 空跑（查看会执行什么，不会真正调用任何 API）
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## 依赖要求

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）或 `apt install jq`（Linux）
- **coreutils**（仅 macOS，用于 timeout 命令）：`brew install coreutils`

## 用法

```bash
./adversarial_review.sh [选项] <slot_a> <slot_b> <目标目录>

选项：
    -h, --help              显示帮助
    -m, --max-iters N       最大迭代次数（默认：3）
    -p, --prompt FILE       为本次运行追加阶段一审查标准
    -v, --verbose           详细输出
    -t, --timeout MIN       每个智能体调用的超时时间，单位分钟（默认：10）
    -f, --fixer AGENT       阶段四由谁来实施修复：claude | codex
                            （省略时，在交互终端会询问；
                            非交互场景默认使用 codex）
    --slot-a AGENT          审查槽位 A 的后端：claude | codex
    --slot-b AGENT          审查槽位 B 的后端：claude | codex
    --target-dir PATH       要审查的项目目录
    -b, --base REF          只审查相对该 Git ref 有差异的文件，
                            包括未提交和未跟踪的源文件
    --include-pre-existing  允许阶段四也修复 PRE_EXISTING 问题
                            （默认只报告，不应用修改）
    --status                显示必填目标目录对应的当前状态
    --reset                 重置必填目标目录对应的所有状态
    --reset-circuit         重置必填目标目录对应的断路器
    --circuit-status        显示必填目标目录对应的断路器状态
    --dry-run               只展示会执行什么，不真正运行
```

三个必填输入均可独立使用位置形式或长选项形式，并可任意混用。两个槽位可使用
同一后端；运行会继续，但会警告审查多样性降低。旧的单位置参数形式会被拒绝，
不会把目标路径误解释为槽位 A。

`--base` 是可选的，并且不会自动推断。设置后，阶段一只审查相对该 ref
发生差异的可审查源文件，包括已提交、已暂存、未暂存和未跟踪的工作；
既有的扩展名白名单以及生成目录／第三方目录排除规则仍然生效。ref 无效、
目标不是 Git 工作树，或最终范围为空时，脚本会在调用任何智能体之前失败。
不传 `--base` 时，原有的全目录扫描行为不变。建议配合 `--dry-run` 先检查
解析后的模式、文件数量和文件列表，再消耗 API 额度。

每条发现都带有 `IN_SCOPE` 或 `PRE_EXISTING` 标签。传入 `--base` 时，
变更文件边界用于默认分类；未传入时，智能体通过受影响行的 `git blame`/
`git log` 判断历史归属。阶段四默认只修复 `IN_SCOPE`，并单独列出历史问题。
只有明确希望同时修复两类问题时才使用 `--include-pre-existing`。dry-run
会显示实际组装的阶段四策略，`--status <slot_a> <slot_b> <目标目录>` 会按范围显示已修复／
仅标记的数量。

状态是按目标目录隔离的（见下方"状态目录"一节），所以想查看或重置某个项目的历史，需要把必填的槽位配置和当初审查它时用的 `<目标目录>` 传给 `--status`/`--reset` 等命令。

## 项目结构

```
adversarial-review/
├── adversarial_review.sh    # 主脚本
├── lib/
│   ├── date_utils.sh        # 跨平台日期工具
│   ├── circuit_breaker.sh   # 防止死循环
│   └── response_analyzer.sh # 解析智能体输出
├── prompts/
│   ├── initial_review.md    # 阶段一：独立审查 prompt
│   ├── cross_review.md      # 阶段二：交叉审查 prompt
│   ├── meta_review.md       # 阶段三：元审查 prompt
│   └── synthesis.md         # 阶段四：综合 prompt
└── state/                   # 按目标目录隔离的状态（已加入 .gitignore）
    └── <项目 slug>-<hash>/
        ├── artifacts/        # 每轮迭代的智能体输出
        ├── logs/             # 执行日志
        ├── tracking.json     # 状态追踪
        └── .circuit_breaker.json
```

## 状态目录

每个被审查过的目标目录都会在 `state/` 下拥有自己独立的状态文件夹，命名规则是"目录名 + 完整路径的短 hash"（这样两个不同位置但同名的目录也不会撞在一起）。这意味着：

- 审查完项目 A 再审查项目 B，两者的 `tracking.json` 历史、产出文件、断路器计数都不会混在一起。
- 项目 A 留下的 OPEN 断路器（或者一次遗留的 `--dry-run`）不会拦下或污染项目 B 的运行。
- `--status`/`--reset`/`--circuit-status`/`--reset-circuit` 都要求提供两个槽位配置和目标目录，用来精确定位到该项目的状态。

## 断路器（Circuit Breaker）

通过检测以下情况来防止死循环：

- **无进展**：连续 3 轮迭代都没有实施任何修复
- **持续分歧**：连续 5 轮以上双方无法达成一致
- **重复问题**：连续 3 轮以上发现同样但无法修复的问题

```bash
# 查看某个项目的断路器状态
./adversarial_review.sh --circuit-status claude codex ../my-project

# 卡住时重置
./adversarial_review.sh --reset-circuit claude codex ../my-project
```

## 自定义

### 自定义审查 Prompt

```bash
# 为本次运行追加审查标准
./adversarial_review.sh -p my_review_prompt.md claude codex ../project
```

脚本会在参数验证期间读取该文件一次，并把内容作为带边界标记的标准区段追加到
内置阶段一 Prompt。它不会替换 Agent ID Header、工作目录上下文、审查范围、
Finding Scope 规则或必需的 Status Block，也不会修改 `prompts/` 下的文件。
路径缺失、不可读或不是普通文件时，会在任一智能体启动前失败。不同运行的标准
彼此隔离。

阶段一至阶段三在各 Backend 的调用边界强制只读。Claude 只能使用读取／搜索
工具以及受限批准的 `git log` 和 `git blame` 命令，并采用非交互拒绝模式；
Codex 使用只读沙箱。只有阶段四选定的 Fixer 获得写权限。

### 环境变量

```bash
MAX_ITERATIONS=5      # 覆盖最大迭代次数
TIMEOUT_MINUTES=15    # 每次智能体调用的超时时间
VERBOSE=1             # 开启详细输出
DRY_RUN=1             # 只展示会执行什么
FIXER=codex           # 阶段四由谁实施修复：claude | codex
```

## 工作原理

### 智能体状态块

每个智能体的输出末尾都会包含一个结构化状态块，供脚本解析：

```
---REVIEW_STATUS---
ISSUES_FOUND: 3
CRITICAL_COUNT: 1
HIGH_COUNT: 1
MEDIUM_COUNT: 1
LOW_COUNT: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING, CLAUDE-3=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Found critical type mixing bug
---END_REVIEW_STATUS---
```

### 退出条件

以下任一情况会结束循环：
1. **阶段一中双方都报告 NO_ISSUES**
2. **综合阶段完成且 EXIT_SIGNAL: true**
3. **达到最大迭代次数**
4. **断路器触发**（检测到停滞）

### 产出文件（Artifacts）

每轮迭代会产生：
- `iter{N}_1_<backend>_review.md` - 槽位 A 的初始审查
- `iter{N}_1_<backend>_review.md` - 槽位 B 的初始审查
- `iter{N}_2_<backend>_on_<other_backend>.md` - 交叉审查
- `iter{N}_3_<backend>_meta.md` - 元审查
- `iter{N}_4_synthesis.md` - 最终综合结果与修复内容

`<backend>` 始终使用实际的 `claude` 或 `codex`，不会改成槽位名。异构配置保留
既有路径；同后端配置中，未改变的文件名分别放在 `artifacts/slot-a/` 与
`artifacts/slot-b/` 下，以避免文件冲突。

每份智能体回复都有对应的 `*.invocation.json`，记录阶段、Backend、原生权限／
Sandbox 模式、允许的工具以及是否授权写入。审查调用还会保留结构化
`*.raw.log` 事件（Claude `stream-json`、Codex `--json`），用于审计被拒绝或
越权的写入请求；如果检测到 Target 发生变化，流程会生成
`iter{N}_phase_*_write_violation.json` 指纹记录并停止，但不会回滚用户文件。

以上每个 Codex 生成的文件也有一份对应的 `iter{N}_*_*.raw.log`。`codex exec`
的标准输出是完整的 agent 执行记录（推理摘要、shell/工具调用、文件转储），而不只是
最终答案，所以 `.md` 文件是通过 `codex exec -o`（`--output-last-message`）提取出
来的，只保留最终回复，这样喂进后续阶段的 prompt 时体积不会滚雪球式膨胀。完整记录
则保留在 `.raw.log` 里供调试查看。

## 研究背景

这套方法基于以下研究：

- [D3: Debate, Deliberate, Decide](https://arxiv.org/abs/2410.04663) - 对抗式多智能体评估框架
- [ChatEval](https://github.com/thunlp/ChatEval) - 面向 LLM 评估的多智能体辩论
- [AI Debate Research](https://arxiv.org/html/2410.04663v1) - 表明辩论式 LLM 能产出更准确的结果

主要研究结论：
- 多智能体辩论能减少幻觉和误报
- 3-7 个智能体在准确率与成本之间的性价比最佳
- 对抗式验证能提升共识质量

## 成本考量

每轮迭代会产生 6 次 API 调用（3 组并行调用）：
- 阶段一：2 次调用（槽位 A + 槽位 B）
- 阶段二：2 次调用（槽位 A + 槽位 B）
- 阶段三：2 次调用（槽位 A + 槽位 B）
- 阶段四：1 次调用（由 `--fixer` 选定的那个智能体）

最多 3 轮迭代时，最坏情况约为每次审查 21 次 API 调用。

有两个改动能让单次调用的开销更小：
- **阶段一不再把完整文件内容内联进 prompt。** 智能体拿到的是一份文件路径
  清单（从第二轮迭代起还会附上自上一轮以来的 `git diff`），需要时自己用
  工具去读取所需文件，而不是把整个代码库都粘贴进 prompt。
- **`--fixer` 让你可以把最重的一步（阶段四会重新携带完整的第 1-3 阶段辩论
  历史）路由给额度更充裕的那个智能体。** 非交互运行时默认使用 Codex，
  这样这部分开销默认不会全部落在 Claude 的额度上。

## 参与贡献

这是一个实验性原型。可以改进的方向包括：
- 支持更多模型（Gemini、本地 LLM 等）
- 基于历史准确率实现加权投票
- 加入成本追踪与预算控制
- 构建用于查看产出文件的 Web 界面

## 许可证

MIT
