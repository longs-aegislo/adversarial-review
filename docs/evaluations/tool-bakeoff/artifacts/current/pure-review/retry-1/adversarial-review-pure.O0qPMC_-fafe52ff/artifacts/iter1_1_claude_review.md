三处均为相对 `benchmark-base` 的确认回归,直接违反 REQUIREMENTS.md:

1. **CLAUDE-1**(`isSafeRedirect`):丢失了对 `//` 协议相对 URL 的拒绝检查,导致开放重定向漏洞。
2. **CLAUDE-2**(`retryDelay`):指数从 `attempt-1` 改为 `attempt`,首次重试延迟翻倍,偏离"一基数"约定。
3. **CLAUDE-3**(`take`):用 `count-1` 代替 `count` 做切片,少返回一个元素,`count=0` 时行为更是完全错误。
