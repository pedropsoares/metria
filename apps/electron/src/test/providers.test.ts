import test from "node:test";
import assert from "node:assert/strict";

test("usage percentages are presented as bounded values", () => {
  const bounded = (value: number) => Math.max(0, Math.min(100, value));
  assert.equal(bounded(-4), 0);
  assert.equal(bounded(45), 45);
  assert.equal(bounded(101), 100);
});
