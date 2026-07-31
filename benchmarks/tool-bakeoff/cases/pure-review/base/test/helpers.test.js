import assert from "node:assert/strict";
import test from "node:test";

import { isSafeRedirect, retryDelay, take } from "../src/helpers.js";

test("ordinary values remain usable", () => {
  assert.equal(isSafeRedirect("/dashboard"), true);
  assert.equal(Number.isFinite(retryDelay(2, 100)), true);
  assert.deepEqual(take(["a", "b"], 5), ["a", "b"]);
});
