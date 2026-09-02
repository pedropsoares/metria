import test from "node:test";
import assert from "node:assert/strict";
import { base64URL, encryptionKeyFromSecret, localTokenFromSecret, secretFromWords, topicFromSecret, wordsFromSecret } from "../main/pairing-secret";

// A phone paired with the macOS app has to read snapshots published by this one, so the
// derivations must agree byte for byte. These values were produced by CryptoKit through
// Sources/MetriaCore/PairingSecret.swift for the same secret.
const SECRET = Buffer.from("00112233445566778899aabbccddeeff", "hex");
const PHRASE = "abandon math mimic master filter design carbon crystal rookie group knife young";

test("derives the same topic, key, and local token as the native app", () => {
  assert.equal(topicFromSecret(SECRET), "e0475c1661646666db01b086551ab88d");
  assert.equal(encryptionKeyFromSecret(SECRET).toString("hex"), "e27be4cc8b460e4ccf508dac3b1bb2fa530d32755f4260ae089ddb5cad6de298");
  assert.equal(localTokenFromSecret(SECRET), "f30R9EB69ntqjlV2XGsIn1n7fHMUEgaAkwl13dTypT0");
  assert.equal(base64URL(SECRET), "ABEiM0RVZneImaq7zN3u_w");
});

test("encodes the secret as the same 12-word phrase the native app shows", () => {
  assert.equal(wordsFromSecret(SECRET).join(" "), PHRASE);
  assert.deepEqual(secretFromWords(PHRASE.split(" ")), SECRET);
});

test("accepts a phrase typed in any case and round-trips random secrets", () => {
  assert.deepEqual(secretFromWords(PHRASE.toUpperCase().split(" ")), SECRET);
  for (let attempt = 0; attempt < 50; attempt++) {
    const secret = Buffer.from(Array.from({ length: 16 }, () => Math.floor(Math.random() * 256)));
    assert.deepEqual(secretFromWords(wordsFromSecret(secret)), secret);
  }
});

test("rejects a mistyped phrase instead of deriving the wrong topic", () => {
  const words = PHRASE.split(" ");
  assert.equal(secretFromWords([...words.slice(0, 11), "zoo"]), null, "checksum mismatch");
  assert.equal(secretFromWords([...words.slice(0, 11), "notaword"]), null, "unknown word");
  assert.equal(secretFromWords(words.slice(0, 11)), null, "wrong length");
});
