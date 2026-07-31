# Pagination requirements

- `parsePageSize(raw)` returns an integer from 1 through 100, or `null`.
- `pageBounds(page, size)` uses zero-based page numbers and returns inclusive
  `{ start, end }` indexes for that page.

The `parsePageSize` zero-handling defect predates the `pageBounds` change and is
intentionally outside the implementation scope.
