import { createCipheriv, hkdfSync, randomBytes } from "node:crypto";
import { readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { safeStorage } from "electron";

/** Keeps the pairing secret local. A device cannot be paired unless Electron's secure storage is available. */
export class PairingStore {
  constructor(private readonly path: string) {}

  status(): "available" | "unavailable" { return safeStorage.isEncryptionAvailable() ? "available" : "unavailable"; }

  loadOrCreate(): Buffer | undefined {
    if (this.status() !== "available") return undefined;
    try {
      const value = safeStorage.decryptString(readFileSync(this.path));
      return /^[a-f0-9]{32}$/i.test(value) ? Buffer.from(value, "hex") : undefined;
    } catch {
      return this.save(randomBytes(16));
    }
  }

  rotate(): Buffer | undefined {
    if (this.status() !== "available") return undefined;
    return this.save(randomBytes(16));
  }

  remove(): void { try { unlinkSync(this.path); } catch { /* The file may not exist. */ } }

  private save(secret: Buffer): Buffer | undefined {
    try {
      const temporary = `${this.path}.tmp`;
      writeFileSync(temporary, safeStorage.encryptString(secret.toString("hex")), { mode: 0o600 });
      renameSync(temporary, this.path);
      return secret;
    } catch { return undefined; }
  }
}

export function encryptedSnapshot(values: Array<{ kind: string; windows: Array<{ percent: number; resetDate: string | null }> }>, secret: Buffer): { snapshot: Buffer; topic: string; body: string } {
  const snapshot = Buffer.from(JSON.stringify({
    updatedAt: new Date().toISOString(),
    providers: values.flatMap((value) => value.windows[0] ? [{ name: value.kind, percent: value.windows[0].percent, resetDate: value.windows[0].resetDate }] : [])
  }));
  const key = Buffer.from(hkdfSync("sha256", secret, Buffer.alloc(0), Buffer.from("metria-key-v1"), 32));
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const body = Buffer.concat([iv, cipher.update(snapshot), cipher.final(), cipher.getAuthTag()]).toString("base64");
  const topic = Buffer.from(hkdfSync("sha256", secret, Buffer.alloc(0), Buffer.from("metria-topic-v1"), 16)).toString("hex");
  return { snapshot, topic, body };
}

export function shouldPublish(phoneSyncEnabled: boolean, secret: Buffer | undefined): boolean { return phoneSyncEnabled && secret !== undefined; }
