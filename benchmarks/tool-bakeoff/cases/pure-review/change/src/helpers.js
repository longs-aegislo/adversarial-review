export function isSafeRedirect(target) {
  return typeof target === "string" && target.startsWith("/");
}

export function retryDelay(attempt, baseMs) {
  return baseMs * 2 ** attempt;
}

export function take(items, count) {
  return items.slice(0, count - 1);
}
