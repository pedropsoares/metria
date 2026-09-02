import { encryptionKeyFromSecret, topicFromSecret } from "./pairing-secret";
import { buildSnapshot, sealSnapshot } from "./snapshot";
import type { ProviderUsage } from "../shared/types";

/**
 * Publishes each refreshed snapshot to the pairing topic on ntfy, encrypted with a key
 * only paired devices can derive. Mirrors the macOS app's `NtfyPublisher`: the server
 * sees ciphertext and a topic name, never usage data.
 */
export class NtfyPublisher {
  private inFlight: AbortController | undefined;
  /** Called with the plaintext snapshot so the LAN server can serve the same bytes. */
  onSnapshot: ((payload: Buffer) => void) | undefined;

  publish(providers: ProviderUsage[], secret: Buffer, server: string): void {
    let topicURL: URL;
    try {
      const base = new URL(server);
      if (base.protocol !== "https:") return;
      topicURL = new URL(topicFromSecret(secret), base.href.endsWith("/") ? base.href : `${base.href}/`);
    } catch {
      return;
    }

    const payload = Buffer.from(JSON.stringify(buildSnapshot(providers)), "utf8");
    this.onSnapshot?.(payload);

    // Superseding an in-flight publish is safe: the newest snapshot is the only one
    // paired devices need, so a cancelled older request is not losing data.
    this.inFlight?.abort();
    const controller = new AbortController();
    this.inFlight = controller;
    void fetch(topicURL, {
      method: "POST",
      body: sealSnapshot(payload, encryptionKeyFromSecret(secret)),
      headers: { "Content-Type": "text/plain", Priority: "low" },
      signal: controller.signal
    }).catch(() => undefined);
  }

  stop(): void { this.inFlight?.abort(); this.inFlight = undefined; }
}
