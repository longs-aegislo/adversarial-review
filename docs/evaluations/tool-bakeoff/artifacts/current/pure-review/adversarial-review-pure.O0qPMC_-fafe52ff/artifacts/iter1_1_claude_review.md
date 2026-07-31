我发现了 `src/helpers.js` 中三处与 REQUIREMENTS.md 明确冲突的正确性回归问题:

1. **CLAUDE-1** `isSafeRedirect`(第2行):只检查以 `/` 开头,未排除协议相对 URL(如 `//evil.com`),违反了需求中"protocol-relative URLs 视为不安全"的规定,构成开放重定向漏洞。
2. **CLAUDE-2** `retryDelay`(第6行):使用 `baseMs * 2 ** attempt`,但需求要求第 1 次尝试应等于 `baseMs`(即 `2 ** (attempt - 1)`),导致所有重试延迟都翻倍。
3. **CLAUDE-3** `take`(第10行):使用 `count - 1` 而非 `count`,导致返回结果总是少一个元素。

现有测试(test/helpers.test.js)覆盖较弱,未能捕获这些偏差。
