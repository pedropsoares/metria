import test from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv } from "node:crypto";
import { buildSnapshot, sealSnapshot } from "../main/snapshot";
import { encryptionKeyFromSecret } from "../main/pairing-secret";
import type { ProviderUsage } from "../shared/types";

function provider(kind: ProviderUsage["kind"], windows: ProviderUsage["windows"]): ProviderUsage {
  return { kind, accountLabel: null, windows, updatedAt: null, error: null, available: true, setupHint: "" };
}

test("publishes the primary window of each provider in the shared wire format", () => {
  const snapshot = buildSnapshot([
    provider("Claude", [{ title: "Session", percent: 42.5, resetDate: "2026-09-02T15:04:05.123Z" }, { title: "Weekly", percent: 10, resetDate: null }]),
    provider("Codex", [{ title: "Session", percent: 7, resetDate: null }]),
    provider("Cursor", [])
  ], new Date("2026-09-02T15:00:00.456Z"));

  assert.deepEqual(snapshot, {
    updatedAt: "2026-09-02T15:00:00Z",
    providers: [
      { name: "Claude", percent: 42.5, resetDate: "2026-09-02T15:04:05Z" },
      { name: "Codex", percent: 7 }
    ]
  });
});

// The iOS app decodes these with a strict ISO-8601 decoder, which rejects fractional
// seconds, and it drops a provider whose `resetDate` is present but null.
test("keeps dates at second precision and omits an unknown reset date", () => {
  const snapshot = buildSnapshot([provider("Claude", [{ title: "Session", percent: 1, resetDate: "not a date" }])]);
  assert.match(snapshot.updatedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal("resetDate" in snapshot.providers[0]!, false);
});

// Paired phones and the PWA render "$130 / $250" from these, so the amounts have to
// survive the trip; a provider that reports no money must not gain empty fields.
test("carries the primary window's spend amounts when the provider reports them", () => {
  const snapshot = buildSnapshot([
    provider("Cursor", [{ title: "This cycle", percent: 52, resetDate: null, usedCents: 13000, limitCents: 25000 }]),
    provider("Claude", [{ title: "Session", percent: 12, resetDate: null }])
  ]);
  assert.deepEqual(snapshot.providers, [
    { name: "Cursor", percent: 52, usedCents: 13000, limitCents: 25000 },
    { name: "Claude", percent: 12 }
  ]);
});

test("seals the snapshot the way CryptoKit's combined sealed box is laid out", () => {
  const key = encryptionKeyFromSecret(Buffer.from("00112233445566778899aabbccddeeff", "hex"));
  const payload = Buffer.from(JSON.stringify(buildSnapshot([provider("Claude", [{ title: "Session", percent: 42, resetDate: null }])])), "utf8");
  const combined = Buffer.from(sealSnapshot(payload, key), "base64");

  const nonce = combined.subarray(0, 12);
  const tag = combined.subarray(combined.length - 16);
  const ciphertext = combined.subarray(12, combined.length - 16);
  assert.equal(ciphertext.length, payload.length);

  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(tag);
  assert.deepEqual(Buffer.concat([decipher.update(ciphertext), decipher.final()]), payload);
});

test("uses a fresh nonce for every snapshot", () => {
  const key = encryptionKeyFromSecret(Buffer.alloc(16, 7));
  const payload = Buffer.from("{}", "utf8");
  assert.notEqual(sealSnapshot(payload, key), sealSnapshot(payload, key));
});
