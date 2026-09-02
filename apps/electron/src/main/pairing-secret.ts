import { createHash, hkdfSync, randomBytes } from "node:crypto";
import { BIP39_WORDLIST } from "./bip39-wordlist";

/**
 * Port of the macOS app's `Sources/MetriaCore/PairingSecret.swift`. The same 16-byte
 * secret must derive the same ntfy topic, AES-256 key, and local token here, in the
 * native app, in the PWA (`apps/pwa/public/pairing.js`), and in the iOS app — a phone
 * paired against any of them has to read snapshots from all of them.
 */
export const ENTROPY_BYTE_COUNT = 16;
const WORD_COUNT = 12;
const CHECKSUM_BIT_COUNT = (ENTROPY_BYTE_COUNT * 8) / 32;

export function generateSecret(): Buffer { return randomBytes(ENTROPY_BYTE_COUNT); }

/** Encodes the secret as a 12-word phrase with the BIP-39 SHA-256 checksum appended. */
export function wordsFromSecret(secret: Buffer): string[] {
  if (secret.length !== ENTROPY_BYTE_COUNT) throw new Error("Invalid pairing secret length.");
  const bits = [...bitsFrom(secret), ...checksumBits(secret)];
  const words: string[] = [];
  for (let index = 0; index < bits.length; index += 11) {
    words.push(BIP39_WORDLIST[bits.slice(index, index + 11).reduce((value, bit) => (value << 1) | bit, 0)]!);
  }
  return words;
}

/** Reverses `wordsFromSecret`, returning null when a word is unknown or the checksum fails. */
export function secretFromWords(words: string[]): Buffer | null {
  if (words.length !== WORD_COUNT) return null;
  const bits: number[] = [];
  for (const word of words) {
    const index = BIP39_WORDLIST.indexOf(word.toLowerCase());
    if (index === -1) return null;
    for (let shift = 10; shift >= 0; shift--) bits.push((index >> shift) & 1);
  }
  const entropy = bytesFrom(bits.slice(0, ENTROPY_BYTE_COUNT * 8));
  const provided = bits.slice(ENTROPY_BYTE_COUNT * 8);
  const expected = checksumBits(entropy);
  return provided.every((bit, index) => bit === expected[index]) ? entropy : null;
}

/** The ntfy topic. Not a secret on its own; confidentiality comes from `encryptionKey`. */
export function topicFromSecret(secret: Buffer): string {
  return derive(secret, "metria-topic-v1", 16).toString("hex");
}

/** The AES-256-GCM key protecting every snapshot published to the ntfy relay. */
export function encryptionKeyFromSecret(secret: Buffer): Buffer {
  return derive(secret, "metria-key-v1", 32);
}

/** The token new clients send to the local `/snapshot` endpoint, so a header captured on
 * the LAN cannot also unlock the ntfy relay the master secret protects. */
export function localTokenFromSecret(secret: Buffer): string {
  return base64URL(derive(secret, "metria-local-token-v1", 32));
}

export function base64URL(bytes: Buffer): string {
  return bytes.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function derive(secret: Buffer, info: string, byteCount: number): Buffer {
  return Buffer.from(hkdfSync("sha256", secret, Buffer.alloc(0), Buffer.from(info, "utf8"), byteCount));
}

function checksumBits(entropy: Buffer): number[] {
  return bitsFrom(createHash("sha256").update(entropy).digest()).slice(0, CHECKSUM_BIT_COUNT);
}

function bitsFrom(data: Buffer): number[] {
  const bits: number[] = [];
  for (const byte of data) for (let shift = 7; shift >= 0; shift--) bits.push((byte >> shift) & 1);
  return bits;
}

function bytesFrom(bits: number[]): Buffer {
  const bytes = Buffer.alloc(bits.length / 8);
  for (let index = 0; index < bytes.length; index++) {
    bytes[index] = bits.slice(index * 8, index * 8 + 8).reduce((value, bit) => (value << 1) | bit, 0);
  }
  return bytes;
}
