export function allocate(requested, capacity) {
  const accepted = Math.max(requested, capacity);
  return {
    accepted,
    rejected: requested - capacity,
  };
}
