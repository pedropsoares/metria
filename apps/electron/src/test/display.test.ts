import test from "node:test";
import assert from "node:assert/strict";
import { cardBounds, estimateCardHeight, NOTCH, railBounds } from "../main/display";

test("rail stays flush to the active display right edge", () => {
  const area = { x: 1920, y: 0, width: 2560, height: 1400 };
  assert.deepEqual(railBounds(area, { pinned: true, hovered: false }), { x: 1920 + 2560 - NOTCH.idleWidth, y: 12, width: NOTCH.idleWidth, height: NOTCH.compactHeight });
  assert.deepEqual(railBounds(area, { pinned: false, hovered: true }), { x: 1920 + 2560 - NOTCH.idleWidth, y: 12, width: NOTCH.idleWidth, height: NOTCH.hoverHeight });
  assert.deepEqual(railBounds(area, { pinned: false, hovered: false }), { x: 1920 + 2560 - NOTCH.hiddenWidth, y: 12, width: NOTCH.hiddenWidth, height: NOTCH.hiddenHeight });
});

test("card sits left of the rail aligned to the hovered provider", () => {
  const area = { x: 1920, y: 0, width: 2560, height: 1400 };
  const bounds = cardBounds(area, 1, 200);
  assert.equal(bounds.x, 1920 + 2560 - NOTCH.idleWidth - NOTCH.cardSpacing - NOTCH.cardWidth);
  assert.equal(bounds.width, NOTCH.cardWidth);
  assert.equal(bounds.height, 200);
  assert.ok(bounds.y >= area.y + 8 && bounds.y <= area.y + area.height - 208);
});

test("card height estimate grows with windows", () => {
  assert.ok(estimateCardHeight(0) < estimateCardHeight(3));
  assert.ok(estimateCardHeight(10) <= 520);
});
