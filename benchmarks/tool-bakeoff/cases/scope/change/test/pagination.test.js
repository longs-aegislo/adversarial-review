import assert from "node:assert/strict";
import test from "node:test";

import { pageBounds, parsePageSize } from "../src/pagination.js";

test("ordinary page sizes parse", () => {
  assert.equal(parsePageSize("25"), 25);
  assert.equal(parsePageSize("101"), null);
});

test("first page begins at zero", () => {
  assert.equal(pageBounds(0, 25).start, 0);
});
