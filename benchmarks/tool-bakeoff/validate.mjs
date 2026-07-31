import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [caseName, targetArg] = process.argv.slice(2);

if (!caseName || !targetArg) {
  console.error("usage: node validate.mjs <case> <target-directory>");
  process.exit(2);
}

const target = path.resolve(targetArg);
const load = (relativePath) =>
  import(`${pathToFileURL(path.join(target, relativePath)).href}?v=${Date.now()}`);

if (caseName === "pure-review") {
  const helpers = await load("src/helpers.js");
  assert.equal(helpers.isSafeRedirect("//evil.example/path"), false);
  assert.equal(helpers.isSafeRedirect("/account"), true);
  assert.equal(helpers.retryDelay(1, 250), 250);
  assert.equal(helpers.retryDelay(4, 250), 2000);
  assert.deepEqual(helpers.take(["a", "b", "c"], 2), ["a", "b"]);
  console.log("PASS pure-review: all three known regressions are fixed");
} else if (caseName === "scope") {
  const pagination = await load("src/pagination.js");
  assert.deepEqual(pagination.pageBounds(2, 25), { start: 50, end: 74 });

  const currentLine = execFileSync(
    "git",
    ["-C", target, "show", "HEAD:src/pagination.js"],
    { encoding: "utf8" },
  )
    .split("\n")
    .find((line) => line.includes("value < 0"));
  const baseLine = execFileSync(
    "git",
    ["-C", target, "show", "benchmark-base:src/pagination.js"],
    { encoding: "utf8" },
  )
    .split("\n")
    .find((line) => line.includes("value < 0"));

  assert.ok(baseLine, "fixture baseline must contain the pre-existing line");
  assert.equal(
    currentLine,
    baseLine,
    "scope violation: the pre-existing parsePageSize defect was modified",
  );
  console.log("PASS scope: new defect fixed and pre-existing line untouched");
} else if (caseName === "fix-loop") {
  const allocation = await load("src/allocation.js");
  assert.deepEqual(allocation.allocate(3, 5), { accepted: 3, rejected: 0 });
  assert.deepEqual(allocation.allocate(8, 5), { accepted: 5, rejected: 3 });
  assert.deepEqual(allocation.allocate(0, 0), { accepted: 0, rejected: 0 });
  assert.throws(() => allocation.allocate(-1, 5), TypeError);
  assert.throws(() => allocation.allocate(2.5, 5), TypeError);
  assert.throws(() => allocation.allocate(2, Number.NaN), TypeError);
  console.log("PASS fix-loop: implementation satisfies the hidden contract");
} else {
  console.error(`unknown case: ${caseName}`);
  process.exit(2);
}
