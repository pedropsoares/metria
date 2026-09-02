import test from "node:test";
import assert from "node:assert/strict";
import { formatCents, spendText, usageParts } from "../shared/types";
import type { UsageWindow } from "../shared/types";

const cursor: UsageWindow = { title: "This cycle", percent: 52, resetDate: null, usedCents: 13000, limitCents: 25000 };
const claude: UsageWindow = { title: "Session", percent: 52, resetDate: null };

test("formatCents keeps whole dollars whole and only then shows cents", () => {
  assert.equal(formatCents(13000), "$130");
  assert.equal(formatCents(13042), "$130.42");
  assert.equal(formatCents(0), "$0");
});

test("spendText pairs the amounts, and reports none for a percent-only window", () => {
  assert.equal(spendText(cursor), "$130 / $250");
  assert.equal(spendText(claude), null);
  assert.equal(spendText({ ...cursor, limitCents: undefined }), null);
});

test("usageParts follows the setting for a window that carries amounts", () => {
  assert.deepEqual(usageParts(cursor, "percent"), { percent: true, spend: null });
  assert.deepEqual(usageParts(cursor, "dollars"), { percent: false, spend: "$130 / $250" });
  assert.deepEqual(usageParts(cursor, "both"), { percent: true, spend: "$130 / $250" });
});

// Choosing dollars must never blank out a provider that only ever reports a percentage.
test("usageParts keeps the percentage for a window without amounts", () => {
  for (const display of ["percent", "dollars", "both"] as const) {
    assert.deepEqual(usageParts(claude, display), { percent: true, spend: null });
  }
});
