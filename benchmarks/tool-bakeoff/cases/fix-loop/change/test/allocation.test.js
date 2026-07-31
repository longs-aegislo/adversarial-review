import assert from "node:assert/strict";
import test from "node:test";

import { allocate } from "../src/allocation.js";

test("returns the documented result shape", () => {
  assert.deepEqual(Object.keys(allocate(3, 5)).sort(), ["accepted", "rejected"]);
});
