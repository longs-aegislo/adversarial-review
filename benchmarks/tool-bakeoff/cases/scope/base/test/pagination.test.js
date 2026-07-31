import assert from "node:assert/strict";
import test from "node:test";

import { parsePageSize } from "../src/pagination.js";

test("ordinary page sizes parse", () => {
  assert.equal(parsePageSize("25"), 25);
  assert.equal(parsePageSize("101"), null);
});
