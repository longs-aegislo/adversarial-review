export function parsePageSize(raw) {
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0 || value > 100) {
    return null;
  }
  return value;
}
