# Allocation API

`allocate(requested, capacity)` allocates up to the available capacity.

- Both arguments must be finite, non-negative integers; otherwise throw
  `TypeError`.
- Return `{ accepted, rejected }`.
- `accepted` is the smaller of `requested` and `capacity`.
- `rejected` is the unallocated remainder, never a negative number.
- Inputs are values and must not be mutated.
