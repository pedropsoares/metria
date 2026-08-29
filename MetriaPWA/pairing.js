// Mirrors Sources/MetriaCore/PairingSecret.swift exactly: the same 12-word phrase must
// decode to the same 16-byte secret, and the same secret must derive the same ntfy topic
// and AES-256 key on both sides. See that file for the full explanation of the design.

function bytesToBits(bytes) {
  const bits = [];
  for (const byte of bytes) {
    for (let shift = 7; shift >= 0; shift--) bits.push((byte >> shift) & 1);
  }
  return bits;
}

function bitsToBytes(bits) {
  const bytes = [];
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0;
    for (let j = 0; j < 8; j++) byte = (byte << 1) | bits[i + j];
    bytes.push(byte);
  }
  return new Uint8Array(bytes);
}

async function checksumBits(entropyBytes, count) {
  const hash = await crypto.subtle.digest("SHA-256", entropyBytes);
  return bytesToBits(new Uint8Array(hash)).slice(0, count);
}

// Decodes a 12-word phrase back into the 16-byte secret, validating the checksum so a
// typo is caught here instead of silently producing the wrong topic/key.
async function wordsToSecret(words) {
  if (words.length !== 12) return null;
  const wordlist = window.BIP39_WORDLIST;
  const bits = [];
  for (const word of words) {
    const index = wordlist.indexOf(word);
    if (index === -1) return null;
    for (let shift = 10; shift >= 0; shift--) bits.push((index >> shift) & 1);
  }
  const entropyBits = bits.slice(0, 128);
  const providedChecksum = bits.slice(128, 132);
  const entropyBytes = bitsToBytes(entropyBits);
  const expectedChecksum = await checksumBits(entropyBytes, 4);
  const checksumMatches = expectedChecksum.every((bit, i) => bit === providedChecksum[i]);
  return checksumMatches ? entropyBytes : null;
}

// Encodes the 16-byte secret as a 12-word phrase, the reverse of wordsToSecret. Used to
// autofill the phrase field when a QR code / pairing link is opened, so the user sees
// exactly what they're connecting with before it's used.
async function secretToWords(secretBytes) {
  const wordlist = window.BIP39_WORDLIST;
  const checksum = await checksumBits(secretBytes, 4);
  const allBits = bytesToBits(secretBytes).concat(checksum);
  const words = [];
  for (let i = 0; i < allBits.length; i += 11) {
    const chunk = allBits.slice(i, i + 11);
    const value = chunk.reduce((accumulator, bit) => (accumulator << 1) | bit, 0);
    words.push(wordlist[value]);
  }
  return words;
}

function base64UrlToBytes(base64url) {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function bytesToBase64Url(bytes) {
  const binary = String.fromCharCode(...bytes);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function hkdf(secretBytes, infoString, byteLength) {
  const importedKey = await crypto.subtle.importKey("raw", secretBytes, "HKDF", false, ["deriveBits"]);
  const info = new TextEncoder().encode(infoString);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info },
    importedKey,
    byteLength * 8
  );
  return new Uint8Array(bits);
}

// Derives the routing topic (hex string) and the AES-GCM decryption key from the shared
// secret. Both sides run this independently; neither ever transmits the derived values.
async function deriveFromSecret(secretBytes) {
  const topicBytes = await hkdf(secretBytes, "metria-topic-v1", 16);
  const keyBytes = await hkdf(secretBytes, "metria-key-v1", 32);
  const topic = Array.from(topicBytes).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  const cryptoKey = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  return { topic, cryptoKey };
}

// Decrypts a published snapshot. The combined body is IV(12) + ciphertext + tag(16), the
// same layout CryptoKit's AES.GCM.SealedBox.combined produces on the Mac. A message that
// fails here is either encrypted with a different key or forged noise on the topic —
// either way, callers should just ignore it.
async function decryptSnapshot(base64Body, cryptoKey) {
  const combined = base64ToBytes(base64Body);
  const iv = combined.slice(0, 12);
  const data = combined.slice(12);
  const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, cryptoKey, data);
  return JSON.parse(new TextDecoder().decode(plaintext));
}

window.MetriaPairing = { wordsToSecret, secretToWords, base64UrlToBytes, bytesToBase64Url, deriveFromSecret, decryptSnapshot };
