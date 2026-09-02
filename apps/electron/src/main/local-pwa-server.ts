import { createServer, type Server } from "node:http";
import { readFileSync } from "node:fs";
import { primaryIPv4Address } from "./local-network";

/**
 * Serves the same PWA the macOS app serves from `LocalPWAServer`: the static files over
 * the LAN so a phone can pair without any hosted deployment, plus `/snapshot`, the
 * plaintext usage snapshot guarded by a pairing-derived token.
 *
 * Only the PWA's own files are reachable — the request path is matched against a fixed
 * list, never resolved against the filesystem.
 */
const PWA_FILES = new Set([
  "index.html", "app.css", "app.js", "pairing.js", "scanner.js", "jsQR.js", "wordlist.js",
  "sw.js", "manifest.json", "icon.svg", "metria-logo.png", "metria-mascot.png"
]);
const MAXIMUM_PORT_ATTEMPTS = 20;

export class LocalPWAServer {
  /** Resolves a PWA file name to a path on disk; injected so the server carries no
   * dependency on Electron's resource layout. */
  constructor(private readonly findFile: (name: string) => string | undefined) {}

  private server: Server | undefined;
  private snapshot: Buffer | undefined;
  private snapshotTokens = new Set<string>();
  private activePort: number | undefined;
  onURLChange: (() => void) | undefined;

  get port(): number | undefined { return this.activePort; }

  /** The address to put in the pairing link, or null while no LAN address is available. */
  get baseURL(): string | null {
    const address = primaryIPv4Address();
    return this.activePort && address ? `http://${address}:${this.activePort}` : null;
  }

  start(preferredPort: number): void {
    this.stop();
    this.listen(preferredPort, 0);
  }

  stop(): void {
    this.server?.close();
    this.server = undefined;
    this.activePort = undefined;
  }

  updateSnapshot(snapshot: Buffer): void { this.snapshot = snapshot; }

  /** Accepts the legacy base64url master secret (still sent by deployed PWA installs)
   * alongside the newer per-purpose local token, so a header captured on the LAN cannot
   * also unlock the ntfy relay. */
  setSnapshotTokens(tokens: string[]): void {
    this.snapshotTokens = new Set(tokens.filter((token) => token.length > 0));
  }

  private listen(port: number, attempt: number): void {
    if (attempt >= MAXIMUM_PORT_ATTEMPTS || port > 65_535) return;
    const server = createServer((request, response) => { this.respond(request.method, request.url, request.headers["x-metria-secret"], response); });
    server.on("error", () => {
      if (this.server !== server) return;
      this.server = undefined;
      this.activePort = undefined;
      this.listen(port + 1, attempt + 1);
    });
    server.listen(port, () => {
      const address = server.address();
      this.activePort = typeof address === "object" && address ? address.port : port;
      this.onURLChange?.();
    });
    this.server = server;
  }

  private respond(method: string | undefined, url: string | undefined, token: string | string[] | undefined, response: import("node:http").ServerResponse): void {
    const send = (status: number, body: Buffer, contentType = "text/plain; charset=utf-8"): void => {
      response.writeHead(status, { "Content-Type": contentType, "Content-Length": body.length, "Cache-Control": "no-store", Connection: "close" });
      response.end(body);
    };
    if (method !== "GET") { send(405, Buffer.alloc(0)); return; }

    const path = (url ?? "/").split("?")[0] ?? "/";
    if (path === "/snapshot") {
      const presented = Array.isArray(token) ? token[0] : token;
      if (!presented || !this.snapshotTokens.has(presented) || !this.snapshot) { send(204, Buffer.alloc(0)); return; }
      send(200, this.snapshot, "application/json; charset=utf-8");
      return;
    }

    const name = path === "/" ? "index.html" : path.replace(/^\/+/, "");
    const file = PWA_FILES.has(name) ? this.findFile(name) : undefined;
    if (!file) { send(404, Buffer.from("Not Found")); return; }
    try {
      send(200, readFileSync(file), contentTypeFor(name));
    } catch {
      send(500, Buffer.alloc(0));
    }
  }
}

function contentTypeFor(name: string): string {
  switch (name.split(".").pop()) {
    case "html": return "text/html; charset=utf-8";
    case "css": return "text/css; charset=utf-8";
    case "js": return "application/javascript; charset=utf-8";
    case "json": return "application/manifest+json; charset=utf-8";
    case "png": return "image/png";
    case "svg": return "image/svg+xml";
    default: return "application/octet-stream";
  }
}
