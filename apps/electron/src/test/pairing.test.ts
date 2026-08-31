import test from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv, hkdfSync } from "node:crypto";
import { encryptedSnapshot, shouldPublish } from "../main/pairing";

test("sync stays silent unless user consent and a secure secret are both present", () => {
  const secret = Buffer.alloc(16, 7);
  assert.equal(shouldPublish(false, secret), false);
  assert.equal(shouldPublish(true, undefined), false);
  assert.equal(shouldPublish(true, secret), true);
});

test("encrypted snapshots use the native HKDF v1 topic and AES-GCM layout", () => {
  const secret = Buffer.alloc(16, 7);
  const result = encryptedSnapshot([{ kind: "Codex", windows: [{ percent: 42, resetDate: null }] }], secret);
  const expectedTopic = Buffer.from(hkdfSync("sha256", secret, Buffer.alloc(0), Buffer.from("metria-topic-v1"), 16)).toString("hex");
  assert.equal(result.topic, expectedTopic);
  const bytes = Buffer.from(result.body, "base64");
  const key = Buffer.from(hkdfSync("sha256", secret, Buffer.alloc(0), Buffer.from("metria-key-v1"), 32));
  const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, 12));
  decipher.setAuthTag(bytes.subarray(-16));
  assert.deepEqual(Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]), result.snapshot);
});
