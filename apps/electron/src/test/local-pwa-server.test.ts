import test from "node:test";
import assert from "node:assert/strict";
import { request } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalPWAServer } from "../main/local-pwa-server";

const LOCAL_TOKEN = "derived-local-token";
const LEGACY_TOKEN = "legacy-master-secret";

/** Serves a stand-in for the bundled PWA out of a temporary folder. */
function fixture(): { server: LocalPWAServer; cleanup: () => void } {
  const directory = mkdtempSync(join(tmpdir(), "metria-pwa-test-"));
  writeFileSync(join(directory, "index.html"), "<!doctype html><title>Metria</title>");
  writeFileSync(join(directory, "app.js"), "console.log('metria');");
  writeFileSync(join(directory, "secret.txt"), "not part of the PWA");
  const server = new LocalPWAServer((name) => (name === "secret.txt" ? undefined : join(directory, name)));
  server.setSnapshotTokens([LEGACY_TOKEN, LOCAL_TOKEN, ""]);
  return { server, cleanup: () => { server.stop(); rmSync(directory, { recursive: true, force: true }); } };
}

function get(port: number, path: string, token?: string, method = "GET"): Promise<{ status: number; contentType?: string; body: string }> {
  return new Promise((resolve, reject) => {
    const call = request({ host: "127.0.0.1", port, path, method, headers: token ? { "X-Metria-Secret": token } : {} }, (response) => {
      let body = "";
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => resolve({ status: response.statusCode ?? 0, contentType: response.headers["content-type"], body }));
    });
    call.on("error", reject);
    call.end();
  });
}

async function withServer(run: (port: number, server: LocalPWAServer) => Promise<void>): Promise<void> {
  const { server, cleanup } = fixture();
  try {
    server.start(0);
    await new Promise((resolve) => setTimeout(resolve, 50));
    const port = server.port;
    assert.ok(port, "the server is listening");
    await run(port, server);
  } finally { cleanup(); }
}

test("serves the PWA a phone loads over the local network", async () => {
  await withServer(async (port) => {
    const index = await get(port, "/");
    assert.equal(index.status, 200);
    assert.match(index.contentType ?? "", /text\/html/);
    assert.match(index.body, /Metria/);
    assert.equal((await get(port, "/index.html")).status, 200);
    assert.match((await get(port, "/app.js")).contentType ?? "", /application\/javascript/);
  });
});

test("serves nothing but the PWA's own files", async () => {
  await withServer(async (port) => {
    for (const path of ["/secret.txt", "/../package.json", "/settings.json", "/pairing.json"]) {
      assert.equal((await get(port, path)).status, 404, path);
    }
    assert.equal((await get(port, "/", undefined, "POST")).status, 405);
  });
});

test("hands out the snapshot only to a client holding a pairing token", async () => {
  await withServer(async (port, server) => {
    server.updateSnapshot(Buffer.from(JSON.stringify({ updatedAt: "2026-09-02T15:00:00Z", providers: [] })));
    assert.equal((await get(port, "/snapshot")).status, 204, "no token");
    assert.equal((await get(port, "/snapshot", "wrong-token")).status, 204, "wrong token");
    assert.equal((await get(port, "/snapshot", "")).status, 204, "empty token is never valid");

    for (const token of [LEGACY_TOKEN, LOCAL_TOKEN]) {
      const response = await get(port, "/snapshot", token);
      assert.equal(response.status, 200, token);
      assert.match(response.contentType ?? "", /application\/json/);
      assert.equal(JSON.parse(response.body).updatedAt, "2026-09-02T15:00:00Z");
    }
  });
});

test("reports no snapshot until usage has been published", async () => {
  await withServer(async (port) => {
    assert.equal((await get(port, "/snapshot", LOCAL_TOKEN)).status, 204);
  });
});

test("moves to the next port when the preferred one is taken", async () => {
  const { server: first, cleanup: cleanupFirst } = fixture();
  const { server: second, cleanup: cleanupSecond } = fixture();
  try {
    first.start(0);
    await new Promise((resolve) => setTimeout(resolve, 50));
    const taken = first.port;
    assert.ok(taken);
    second.start(taken);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.ok(second.port);
    assert.notEqual(second.port, taken);
  } finally { cleanupFirst(); cleanupSecond(); }
});
