# Pagination requirements

- `parsePageSize(raw)` returns an integer from 1 through 100, or `null`.

The implementation currently has a known legacy defect around zero. That defect
predates the change under review and is intentionally outside the change scope.
