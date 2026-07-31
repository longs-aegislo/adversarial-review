# Helper requirements

- `isSafeRedirect(target)` accepts application-local absolute paths beginning
  with exactly one `/`. Protocol-relative URLs such as `//example.com` are
  unsafe.
- `retryDelay(attempt, baseMs)` uses one-based attempts: attempt 1 waits
  `baseMs`, and each subsequent attempt doubles the delay.
- `take(items, count)` returns at most the first `count` items.
