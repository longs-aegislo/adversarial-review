Bash 工具在本次会话中被持续阻止执行（多次尝试均返回 "This command requires approval"），无法在此环境中运行 `node --test`。以下是基于人工审查完成的修复。

## 发现的 REQUIREMENTS.md 违规（均已修复于 `src/allocation.js`）

- **CLAUDE-1**：`accepted` 使用了 `Math.max(requested, capacity)`，与要求「`accepted` 是 `requested` 和 `capacity` 中较小者」相反 → 已改为 `Math.min`。
- **CLAUDE-2**：`rejected` 计算为 `requested - capacity`，当 `capacity > requested` 时会产生负数，违反「`rejected` 永不为负」的要求 → 已改为 `requested - accepted`（`accepted` 取 min 后必然 ≤ requested，结果非负）。
- **CLAUDE-3**：完全没有对输入做校验，违反「两个参数必须是有限非负整数，否则抛出 `TypeError`」的要求 → 新增 `assertValid` 校验，对非整数（含 `NaN`/`Infinity`/小数）或负数抛出 `TypeError`。

修复后的实现：

```js
function assertValid(value, name) {
  if (!Number.isInteger(value) || value < 0) {
    throw new TypeError(`${name} must be a finite, non-negative integer`);
  }
}

export function allocate(requested, capacity) {
  assertValid(requested, "requested");
  assertValid(capacity, "capacity");

  const accepted = Math.min(requested, capacity);
  return {
    accepted,
    rejected: requested - accepted,
  };
}
```

`test/allocation.test.js` 未做修改——它只校验返回对象的 key 集合，不构成需求违规（只是覆盖较弱），因此未纳入修复范围。

## 复查

再次比对 `src/allocation.js` 与 REQUIREMENTS.md 的每一条：形状 `{accepted, rejected}` ✓、`accepted` 取较小值 ✓、`rejected` 非负 ✓、输入校验 ✓、未对入参做原地修改（原语值不可变，函数内也未修改原变量）✓。未发现新的违规。

**注意**：由于沙箱阻止了 Bash 命令执行，我无法实际运行 `node --test test/allocation.test.js` 来做最终验证，只能通过代码走查确认逻辑正确。建议你在允许执行命令的环境中手动跑一下测试确认。
