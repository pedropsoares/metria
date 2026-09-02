import { createCipheriv, randomBytes } from "node:crypto";
import type { ProviderUsage } from "../shared/types";

/**
 * The wire format Metria publishes to paired clients, defined by the macOS app's
 * `Sources/MetriaCore/UsageSnapshot.swift`. Field names and the second-precision
 * ISO-8601 strings are a cross-client contract — the iOS app decodes them with a strict
 * ISO-8601 decoder, so fractional seconds must not appear.
 */
export interface SnapshotPayload {
  updatedAt: string;
  providers: { name: string; percent: number; resetDate?: string }[];
}

export function buildSnapshot(providers: ProviderUsage[], now = new Date()): SnapshotPayload {
  return {
    updatedAt: iso8601(now)!,
    providers: providers.flatMap((provider) => {
      const primary = provider.windows[0];
      if (!primary) return [];
      const resetDate = iso8601(primary.resetDate ? new Date(primary.resetDate) : null);
      return [{ name: provider.kind, percent: primary.percent, ...(resetDate ? { resetDate } : {}) }];
    })
  };
}

/** AES-256-GCM in the layout CryptoKit's `AES.GCM.SealedBox.combined` produces: the
 * 12-byte nonce, the ciphertext, then the 16-byte tag, base64-encoded. */
export function sealSnapshot(payload: Buffer, key: Buffer): string {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(payload), cipher.final()]);
  return Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]).toString("base64");
}

function iso8601(date: Date | null): string | undefined {
  if (!date || Number.isNaN(date.getTime())) return undefined;
  return `${date.toISOString().slice(0, 19)}Z`;
}
