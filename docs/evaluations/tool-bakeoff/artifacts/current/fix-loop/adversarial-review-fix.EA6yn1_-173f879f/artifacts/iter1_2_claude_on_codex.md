## 交叉审查

### CODEX 逐条核验

**CODEX-1** (`assertValid` 命名不够具体，应为 `assertNonNegativeInteger`)
CODEX-1: VALID — 确实是个合理的风格建议，`assertValid` 语义模糊（"valid" 相对于什么？），而 `assertNonNegativeInteger` 更精确地描述了校验内容。但这纯属命名品味问题，不违反 `REQUIREMENTS.md` 中任何硬性条款，严重性应为 low/nit。
范围：我同意标记为 IN_SCOPE——`assertValid` 函数是本次未提交的修复 diff（`git diff HEAD -- src/allocation.js`）新引入的代码，不存在于 `fa59c7e`（该提交里完全没有校验逻辑），因此这是本次改动引入的命名，非历史遗留问题。

**CODEX-2** (缺少 finite/非负整数校验)
CODEX-2: VALID — 对照 `fa59c7e` 的实现（`git diff 038df33 fa59c7e`），确认原实现完全没有对 `requested`/`capacity` 做任何校验，违反 `REQUIREMENTS.md` "Both arguments must be finite, non-negative integers; otherwise throw `TypeError`" 的要求。当前工作树中 `assertValid`（第1-5行）用 `Number.isInteger(value) || value < 0` 正确修复了这一点（`Number.isInteger` 隐含了 finite 检查，`NaN`/`Infinity`/非整数/负数均会被拒绝）。
范围：IN_SCOPE，该缺陷由 `fa59c7e`（"fixture: add flawed implementation"）引入，baseline commit `038df33` 中该文件只是一个占位注释，无实现可言。

**CODEX-3** (`accepted` 用了 `Math.max` 应为 `Math.min`)
CODEX-3: VALID — `fa59c7e` 第2行确实是 `Math.max(requested, capacity)`，明显与 spec "`accepted` is the smaller of `requested` and `capacity`" 矛盾。当前代码第11行已改为 `Math.min`，修复正确。
范围：IN_SCOPE，同上，由 `fa59c7e` 引入。

**CODEX-4** (`rejected` 可能为负，因为用 capacity 而非 accepted 相减)
CODEX-4: VALID — 原代码 `requested - capacity`：当 `requested < capacity` 时，若同时叠加 CODEX-3 的 bug（`accepted = max(...)  = capacity`），会导致负的 `rejected`，违反 "never a negative number" 的要求。当前代码改为 `requested - accepted`，由于 `accepted = min(requested, capacity) <= requested`，该差值恒 ≥ 0，正确满足契约。
范围：IN_SCOPE，同上。

我逐一手动验证了当前 `allocate` 的四种典型输入（`requested<capacity`、`requested>capacity`、`requested===capacity`、非法输入如负数/小数/字符串/NaN），行为均与 `REQUIREMENTS.md` 完全一致，`npm test` 通过（尽管测试本身覆盖很浅，见下方新增发现）。

## 我新增的发现

- **CLAUDE-ADD-1** — File: `test/allocation.test.js` — Line: 6-8 — Severity: Medium — Scope: PRE_EXISTING（该文件在本次 diff 中未被修改，`git log` 显示自 `fa59c7e` 以来无变更）
  Issue: 测试套件只断言返回对象的 key 集合（`["accepted", "rejected"]`），完全不校验数值是否正确，也没有覆盖非法输入应抛出 `TypeError` 的路径。事实上，如果有人把 `Math.min` 改回 `Math.max`（即重新引入 CODEX-3 描述的原始 bug），或让 `assertValid` 失效，现有测试仍会全部通过——这套测试无法防止本次修复的回归。
  Fix: 建议补充断言具体数值（例如 `allocate(3,5)` 应得到 `{accepted:3, rejected:0}`，`allocate(7,5)` 应得到 `{accepted:5, rejected:2}`），并加一条测试验证对非整数/负数/NaN 输入抛出 `TypeError`。这不属于本次修复 diff 的责任范围（测试文件本身未被触碰），但值得在后续任务中补上。

## VERDICTS

```
VERDICTS: CODEX-1=VALID, CODEX-2=VALID, CODEX-3=VALID, CODEX-4=VALID
SCOPE_VERDICTS: CODEX-1=IN_SCOPE, CODEX-2=IN_SCOPE, CODEX-3=IN_SCOPE, CODEX-4=IN_SCOPE
```

```
---CROSS_REVIEW_STATUS---
FINDINGS_VALIDATED: 4
FINDINGS_CHALLENGED: 0
FINDINGS_ADDED: 1
ISSUE_SCOPES: CODEX-1=IN_SCOPE, CODEX-2=IN_SCOPE, CODEX-3=IN_SCOPE, CODEX-4=IN_SCOPE, CLAUDE-ADD-1=PRE_EXISTING
AGREEMENT_LEVEL: FULL
CONFIDENCE: HIGH
SUMMARY: 对方的三处 spec 违规和一处命名建议全部核实无误、且已被当前工作树正确修复；额外发现测试套件本身覆盖不足，无法防止本类 bug 的回归。
---END_CROSS_REVIEW_STATUS---
```
