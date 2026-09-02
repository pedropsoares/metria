import test from "node:test";
import assert from "node:assert/strict";
import { chooseSource, isExpiredJwt, parseCodexAuth, parseCursorWindows, parseOpenCodeGoWindows } from "../main/providers";
import type { ProviderSourceInfo } from "../shared/types";

function info(host: boolean, present: string[]): Pick<ProviderSourceInfo, "host" | "wsl"> {
  return {
    host,
    wsl: ["Ubuntu", "Debian"].map((distro) => ({ distro, present: present.includes(distro) }))
  };
}

test("chooseSource defaults to host when no preference", () => {
  assert.deepEqual(chooseSource(info(true, []), null), { location: "host" });
  assert.deepEqual(chooseSource(info(true, ["Ubuntu"]), null), { location: "host" });
});

test("chooseSource falls back to WSL when only WSL has data", () => {
  assert.deepEqual(chooseSource(info(false, ["Ubuntu"]), null), { location: "wsl", distro: "Ubuntu" });
});

test("chooseSource respects the saved choice", () => {
  assert.deepEqual(chooseSource(info(true, ["Ubuntu"]), { location: "wsl", distro: "Ubuntu" }), { location: "wsl", distro: "Ubuntu" });
  assert.deepEqual(chooseSource(info(true, ["Ubuntu"]), { location: "host" }), { location: "host" });
});

test("chooseSource falls back when the saved WSL distro no longer has data", () => {
  assert.deepEqual(chooseSource(info(true, ["Ubuntu"]), { location: "wsl", distro: "Debian" }), { location: "host" });
  assert.deepEqual(chooseSource(info(false, ["Ubuntu"]), { location: "wsl", distro: "Debian" }), { location: "wsl", distro: "Ubuntu" });
  assert.deepEqual(chooseSource(info(false, ["Ubuntu"]), { location: "host" }), { location: "wsl", distro: "Ubuntu" });
});

test("chooseSource returns null when no source has data", () => {
  assert.equal(chooseSource(info(false, []), null), null);
});

test("parseCodexAuth reads the current tokens format", () => {
  assert.deepEqual(parseCodexAuth(JSON.stringify({ tokens: { access_token: "access", account_id: "account" } })), { access: "access", accountId: "account" });
});

test("parseCodexAuth keeps supporting the legacy format", () => {
  assert.deepEqual(parseCodexAuth(JSON.stringify({ openai: { access: "access", accountId: "account" } })), { access: "access", accountId: "account" });
});

test("parseOpenCodeGoWindows reads the API reset date", () => {
  assert.deepEqual(parseOpenCodeGoWindows(JSON.stringify({ usage: { rolling: { percent: 12, resetsAt: "2026-09-01T12:00:00.000Z" } } })), [
    { title: "Current session", percent: 12, resetDate: "2026-09-01T12:00:00.000Z" }
  ]);
});

test("parseCursorWindows reads the spend-based plan percent and cycle end", () => {
  const payload = JSON.stringify({ planUsage: { totalPercentUsed: 42.5, autoPercentUsed: 10 }, billingCycleStart: "1756684800000", billingCycleEnd: "1759276800000" });
  assert.deepEqual(parseCursorWindows(payload), [
    { title: "This cycle", percent: 42.5, resetDate: new Date(1759276800000).toISOString() }
  ]);
});

test("parseCursorWindows keeps a missing cycle end as no reset date", () => {
  assert.deepEqual(parseCursorWindows(JSON.stringify({ planUsage: { totalPercentUsed: 0 } })), [
    { title: "This cycle", percent: 0, resetDate: null }
  ]);
});

test("parseCursorWindows measures a plan against its included limit", () => {
  const payload = JSON.stringify({ planUsage: { includedSpend: 1500, limit: 2000, totalPercentUsed: 0 } });
  assert.deepEqual(parseCursorWindows(payload), [{ title: "This cycle", percent: 75, usedCents: 1500, limitCents: 2000, resetDate: null }]);
});

test("parseCursorWindows falls back to the seat spend limit for team and enterprise accounts", () => {
  // What a team seat returns: a planUsage of all zeroes, with the real quota in spendLimitUsage.
  const payload = JSON.stringify({
    planUsage: { totalPercentUsed: 0, autoPercentUsed: 0, apiPercentUsed: 0 },
    spendLimitUsage: { pooledLimit: 3170000, pooledUsed: 0, limitType: "team", overallLimit: 45000, overallUsed: 9000 },
    billingCycleEnd: "1790812800000"
  });
  assert.deepEqual(parseCursorWindows(payload), [
    { title: "This cycle", percent: 20, usedCents: 9000, limitCents: 45000, resetDate: new Date(1790812800000).toISOString() }
  ]);
});

test("parseCursorWindows prefers an individual seat limit over the overall one", () => {
  const payload = JSON.stringify({ spendLimitUsage: { individualUsed: 100, individualLimit: 400, overallUsed: 9000, overallLimit: 45000 } });
  assert.deepEqual(parseCursorWindows(payload), [{ title: "This cycle", percent: 25, usedCents: 100, limitCents: 400, resetDate: null }]);
});

test("parseCursorWindows caps a seat over its limit at 100 percent", () => {
  const payload = JSON.stringify({ spendLimitUsage: { individualUsed: 900, individualLimit: 400 } });
  assert.deepEqual(parseCursorWindows(payload), [{ title: "This cycle", percent: 100, usedCents: 900, limitCents: 400, resetDate: null }]);
});

// A bare percentage carries no money, so the card has nothing to print but the percent.
test("parseCursorWindows leaves out amounts when Cursor reports only a percentage", () => {
  const window = parseCursorWindows(JSON.stringify({ planUsage: { totalPercentUsed: 42.5 } }))[0]!;
  assert.equal("usedCents" in window, false);
  assert.equal("limitCents" in window, false);
});

test("parseCursorWindows rejects a payload without plan usage", () => {
  assert.throws(() => parseCursorWindows(JSON.stringify({ billingCycleEnd: "1759276800000" })), /plan usage/);
});

test("parseCursorWindows rejects a malformed payload", () => {
  assert.throws(() => parseCursorWindows("not json"), /unreadable/);
});

test("isExpiredJwt reads the exp claim without verifying the signature", () => {
  const token = (exp: number): string => `header.${Buffer.from(JSON.stringify({ exp })).toString("base64url")}.signature`;
  assert.equal(isExpiredJwt(token(1_700_000_000), 1_800_000_000_000), true);
  assert.equal(isExpiredJwt(token(1_900_000_000), 1_800_000_000_000), false);
  assert.equal(isExpiredJwt("not-a-jwt"), false);
});
