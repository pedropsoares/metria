import { Server, createServer } from "node:http";
import { readFileSync, statSync } from "node:fs";
import { extname, resolve, sep } from "node:path";

const contentTypes: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "application/javascript; charset=utf-8", ".json": "application/manifest+json; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml" };

export function staticPath(root: string, requestPath: string): string | undefined {
  let decoded: string;
  try { decoded = decodeURIComponent(requestPath); } catch { return undefined; }
  const requested = decoded === "/" ? "index.html" : decoded.replace(/^\/+/, "");
  const base = resolve(root);
  const target = resolve(base, requested);
  return target === base || target.startsWith(`${base}${sep}`) ? target : undefined;
}

export function startLocalPWA(root: string, secret: () => Buffer | undefined, snapshot: () => Buffer): Server {
  const server = createServer((request, response) => {
    const pathname = (request.url ?? "/").split("?", 1)[0];
    if (pathname === "/snapshot") {
      const currentSecret = secret();
      if (!currentSecret || request.headers["x-metria-secret"] !== currentSecret.toString("base64url")) { response.writeHead(204, { "Cache-Control": "no-store" }); return response.end(); }
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
      return response.end(snapshot());
    }
    if (request.method !== "GET" && request.method !== "HEAD") { response.writeHead(405); return response.end(); }
    const path = staticPath(root, pathname);
    try {
      if (!path || !statSync(path).isFile()) throw new Error("not found");
      const headers = { "Content-Type": contentTypes[extname(path)] ?? "application/octet-stream", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Content-Security-Policy": "default-src 'self'; base-uri 'none'; frame-ancestors 'none'" };
      response.writeHead(200, headers);
      response.end(request.method === "HEAD" ? undefined : readFileSync(path));
    } catch { response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8", "X-Content-Type-Options": "nosniff" }); response.end("Not Found"); }
  });
  server.listen(0, "127.0.0.1");
  return server;
}
