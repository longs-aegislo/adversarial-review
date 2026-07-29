[English](README.md) | **中文** | [日本語](README.ja.md)

# Adversarial Review（对抗式代码审查）

基于 Claude 与 GPT Codex 对抗式辩论循环的多智能体代码审查工具。

灵感来自 [asimov-ralph](https://github.com/frankbria/ralph-claude-code) 以及 [AI Debate](https://arxiv.org/abs/2410.04663) 相关研究。

## 关于本 Fork

本仓库 fork 自 [alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review)（原仓库保留为 `upstream` remote）。Fork 之后，我们用一个真实的 Laravel 项目实际跑了这个工具，修复了不少 bug，与上游的主要差异如下：

- **修复了 `codex` 调用方式**：原来的 `run_codex()` 用的是过时的 CLI 语法（`-q --full-auto --prompt`），已经不匹配当前的 `codex` CLI。现在改为 `codex exec -s <sandbox_mode> --skip-git-repo-check`，并通过 stdin 管道传入 prompt，而不是作为位置参数传入（原来的方式在 prompt 较大时会触发 `ARG_MAX` / `timeout: Argument list too long` 报错）。
- **修复了非 JS/Python 技术栈的源码收集逻辑**：原来的 `collect_source_code`/`collect_file_list` 没有排除 `vendor/`、`public/`、`storage/`、`bootstrap/cache/`、`dist/`、`build/`，也不支持 PHP/Blade。结果在 Laravel 项目上，塞进 prompt 的是第三方压缩后的 JS 依赖，而不是项目自己的源码，还直接把 Claude 的上下文长度撑爆了。
- **修复了阶段三丢失对方发现的问题**：原来的元审查 prompt 只重新提供了对方给出的反馈内容，却没有重新提供对方在阶段一的原始发现，也没有提供你自己在阶段二对这些发现做的交叉审查。由于每个阶段都是全新的、无记忆的独立 CLI 调用，这会导致某一方的全部发现在最终共识中悄悄消失。现在 `run_phase_3()` 会为双方都重建完整上下文。
- **修复了 `parse_status_block` 的"取最后一块"逻辑**：原来的实现会把文本中所有 `---STATUS---...---END_STATUS---` 标记对（包括 prompt 模板自带的 EXAMPLE 示例块）全部拼接在一起，产生错乱/重复的 JSON。现在改成基于 awk 的扫描器，只保留最后一个真实的状态块。
- **新增了 `-f/--fixer` 选项**：可以选择由 Claude 还是 Codex 来实施阶段四的修复（可以在交互式终端中被询问，也可以通过参数或环境变量指定），这样就能把最贵的一步交给额度更充裕的那个智能体。
- **重构了阶段一，不再内联完整文件内容**：智能体现在只拿到一份文件路径清单（从第二轮起还会附上相对于 `HEAD` 的 `git diff`），需要什么文件就自己去读，而不是把整个代码库都贴进 prompt——详见下方"成本考量"一节。
- **在终端输出中加入了每个阶段的具体问题摘要**：现在每个阶段都会打印智能体给出的一句话摘要，而不仅仅是问题数量。
- **按目标目录隔离了所有状态**：原来 `tracking.json`、断路器状态、`artifacts/` 都放在仓库根目录，所有跑过的目标项目共用同一份——审查完项目 A 再审查项目 B，两边的 Phase 1 发现会混在一起，甚至项目 A 留下的 OPEN 断路器会直接把项目 B 的运行拦下来。现在状态统一放到 `state/<slug>/` 下，按目标目录路径区分，不同项目之间不会再互相污染。

## 核心理念

两个 AI 智能体（Claude 和 GPT Codex）各自独立审查代码，然后通过多轮辩论互相批判对方的发现。这种对抗式流程有助于：

- **发现更多问题**：不同模型能捕捉到不同的问题
- **消除误报**：交叉验证能过滤掉不正确的发现
- **达成共识**：分歧通过结构化辩论来解决
- **提升置信度**：双方都认同的问题是高置信度的待修复项

## 四阶段循环

```
┌─────────────────────────────────────────────────────────────┐
│  阶段一：独立审查                                             │
│    Claude 审查代码 → claude_review.md                        │
│    Codex 审查代码  → codex_review.md                         │
│    两个智能体只拿到一份文件路径清单（从第二轮起还会附上         │
│    自上一轮以来的 git diff），需要用自己的工具去读取想看的     │
│    文件——不再把整个代码库的文件内容直接塞进 prompt             │
│    （并行执行）                                               │
├─────────────────────────────────────────────────────────────┤
│  阶段二：交叉审查                                             │
│    Claude 审查 Codex 的发现 → claude_on_codex.md              │
│    Codex 审查 Claude 的发现 → codex_on_claude.md              │
│    （并行执行）                                               │
├─────────────────────────────────────────────────────────────┤
│  阶段三：元审查（Meta-Review）                                │
│    Claude 回应 Codex 的批评 → claude_meta.md                  │
│    Codex 回应 Claude 的批评 → codex_meta.md                   │
│    每个智能体都会拿到：自己第一阶段的审查结果、对方第一阶段的  │
│    审查结果、自己在第二阶段对对方发现的交叉审查，以及自己收到  │
│    的反馈——每次都是完整上下文，避免发现在共识阶段悄悄消失      │
│    （并行执行）                                               │
├─────────────────────────────────────────────────────────────┤
│  阶段四：综合与修复                                           │
│    由 Claude 或 Codex（通过 --fixer 选择）审阅全部辩论记录，   │
│    判断哪些问题成立，并对高/中置信度的问题实施修复             │
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
./adversarial_review.sh ../my-project

# 带选项运行
./adversarial_review.sh -m 5 -v ../my-project        # 5 轮迭代，详细输出
./adversarial_review.sh -f codex ../my-project        # 由 Codex 实施修复
./adversarial_review.sh -f claude ../my-project       # 由 Claude 实施修复

# 空跑（查看会执行什么，不会真正调用任何 API）
./adversarial_review.sh --dry-run ../my-project
```

## 依赖要求

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）或 `apt install jq`（Linux）
- **coreutils**（仅 macOS，用于 timeout 命令）：`brew install coreutils`

## 用法

```bash
./adversarial_review.sh [选项] <目标目录>

选项：
    -h, --help              显示帮助
    -m, --max-iters N       最大迭代次数（默认：3）
    -p, --prompt FILE       自定义初始审查 prompt
    -v, --verbose           详细输出
    -t, --timeout MIN       每个智能体调用的超时时间，单位分钟（默认：10）
    -f, --fixer AGENT       阶段四由谁来实施修复：claude | codex
                            （省略时，在交互终端会询问；
                            非交互场景默认使用 codex）
    --status [目录]          显示当前状态（给定目录时按该项目查看）
    --reset [目录]           重置所有状态（给定目录时只重置该项目）
    --reset-circuit [目录]   仅重置断路器（给定目录时只重置该项目）
    --circuit-status [目录]  显示断路器状态（给定目录时只看该项目）
    --dry-run               只展示会执行什么，不真正运行
```

状态是按目标目录隔离的（见下方"状态目录"一节），所以想查看或重置某个项目的历史，把当初审查它时用的 `<目标目录>` 原样传给 `--status`/`--reset` 等命令即可。不传目录时会退回一个共享/全局的兜底位置，仅为向后兼容保留。

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
- `--status`/`--reset`/`--circuit-status`/`--reset-circuit` 都支持传入一个可选的目标目录参数，用来精确定位到该项目的状态。

## 断路器（Circuit Breaker）

通过检测以下情况来防止死循环：

- **无进展**：连续 3 轮迭代都没有实施任何修复
- **持续分歧**：连续 5 轮以上双方无法达成一致
- **重复问题**：连续 3 轮以上发现同样但无法修复的问题

```bash
# 查看某个项目的断路器状态
./adversarial_review.sh --circuit-status ../my-project

# 卡住时重置
./adversarial_review.sh --reset-circuit ../my-project
```

## 自定义

### 自定义审查 Prompt

```bash
# 使用你自己的审查标准
./adversarial_review.sh -p my_review_prompt.md ../project
```

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
- `iter{N}_1_claude_review.md` - Claude 的初始审查
- `iter{N}_1_codex_review.md` - Codex 的初始审查
- `iter{N}_2_claude_on_codex.md` - Claude 的交叉审查
- `iter{N}_2_codex_on_claude.md` - Codex 的交叉审查
- `iter{N}_3_claude_meta.md` - Claude 的元审查
- `iter{N}_3_codex_meta.md` - Codex 的元审查
- `iter{N}_4_synthesis.md` - 最终综合结果与修复内容

以上每个 Codex 生成的文件都还有一份对应的 `iter{N}_*_*.raw.log`。`codex exec`
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
- 阶段一：2 次调用（Claude + Codex）
- 阶段二：2 次调用（Claude + Codex）
- 阶段三：2 次调用（Claude + Codex）
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
