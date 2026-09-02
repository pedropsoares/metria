import { app, safeStorage } from "electron";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pairingLink } from "./pairing-link";
import { base64URL, ENTROPY_BYTE_COUNT, generateSecret, localTokenFromSecret, wordsFromSecret } from "./pairing-secret";
import { qrCodeDataURL } from "./qr";

interface StoredPairing { secret: string; encrypted: boolean; }

/**
 * Owns the pairing master secret and its two presentations — the QR code and the 12-word
 * phrase — the way the macOS app's `PairingKeychain` plus `PairingManager` do. The secret
 * never leaves the machine on its own: a phone only ever receives it by scanning the code
 * or typing the phrase, both of which the user chooses when to show.
 *
 * macOS stores it in the Keychain; here it is a 0600 file in the app's own data folder,
 * encrypted with Electron's `safeStorage` (DPAPI on Windows, the login keyring on Linux)
 * whenever the platform offers OS-backed encryption.
 */
export class PairingStore {
  private readonly path = join(app.getPath("userData"), "pairing.json");
  private secret: Buffer;

  constructor() { this.secret = this.loadOrGenerate(); }

  get currentSecret(): Buffer { return this.secret; }
  get words(): string[] { return wordsFromSecret(this.secret); }
  /** The legacy token: the master secret itself, still sent by deployed PWA installs. */
  get snapshotToken(): string { return base64URL(this.secret); }
  /** The token newer clients send to `/snapshot`, derived so it cannot unlock the relay. */
  get localToken(): string { return localTokenFromSecret(this.secret); }

  regenerate(): void {
    this.secret = generateSecret();
    this.persist(this.secret);
  }

  pairingLink(pwaBaseURL: string, ntfyServer: string, localURL: string | null): string {
    return pairingLink(base64URL(this.secret), pwaBaseURL, ntfyServer, localURL);
  }

  qrDataURL(pwaBaseURL: string, ntfyServer: string, localURL: string | null): string {
    return qrCodeDataURL(this.pairingLink(pwaBaseURL, ntfyServer, localURL));
  }

  private loadOrGenerate(): Buffer {
    const existing = this.load();
    if (existing) return existing;
    const generated = generateSecret();
    this.persist(generated);
    return generated;
  }

  private load(): Buffer | null {
    try {
      const stored = JSON.parse(readFileSync(this.path, "utf8")) as Partial<StoredPairing>;
      if (typeof stored.secret !== "string") return null;
      const raw = Buffer.from(stored.secret, "base64");
      const secret = stored.encrypted ? Buffer.from(safeStorage.decryptString(raw), "base64") : raw;
      return secret.length === ENTROPY_BYTE_COUNT ? secret : null;
    } catch {
      return null;
    }
  }

  private persist(secret: Buffer): void {
    const encrypted = safeStorage.isEncryptionAvailable();
    const stored: StoredPairing = {
      secret: encrypted ? safeStorage.encryptString(secret.toString("base64")).toString("base64") : secret.toString("base64"),
      encrypted
    };
    mkdirSync(dirname(this.path), { recursive: true });
    const temporaryPath = `${this.path}.tmp`;
    writeFileSync(temporaryPath, JSON.stringify(stored), { mode: 0o600 });
    renameSync(temporaryPath, this.path);
  }
}
