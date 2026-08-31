import test from "node:test";
import assert from "node:assert/strict";
import { makeWslShell } from "../main/wsl";

test("wsl distros parses wsl.exe --list --quiet output", async () => {
  const shell = makeWslShell({ platform: "win32", exec: async () => ({ stdout: "Ubuntu\r\nDebian\r\n" }) });
  assert.deepEqual(await shell.distros(), ["Ubuntu", "Debian"]);
});

test("wsl distros returns empty outside Windows", async () => {
  const shell = makeWslShell({ platform: "linux", exec: async () => ({ stdout: "Ubuntu\n" }) });
  assert.deepEqual(await shell.distros(), []);
});

test("wsl distros returns empty when wsl.exe fails", async () => {
  const shell = makeWslShell({ platform: "win32", exec: async () => { throw new Error("wsl not installed"); } });
  assert.deepEqual(await shell.distros(), []);
});

test("wsl presence maps probe tokens", async () => {
  const shell = makeWslShell({ platform: "win32", exec: async () => ({ stdout: "codex_auth\nclaude\n" }) });
  assert.deepEqual(await shell.presence("Ubuntu"), { codex: true, openCode: false, claude: true });
});

test("wsl presence treats codex sessions as codex data", async () => {
  const shell = makeWslShell({ platform: "win32", exec: async () => ({ stdout: "codex_sessions\nopencode\n" }) });
  assert.deepEqual(await shell.presence("Ubuntu"), { codex: true, openCode: true, claude: false });
});

test("wsl presence caches results", async () => {
  const results = new Map();
  let calls = 0;
  const shell = makeWslShell({ platform: "win32", exec: async () => { calls++; return { stdout: "claude\n" }; }, results });
  await shell.presence("Ubuntu");
  await shell.presence("Ubuntu");
  assert.equal(calls, 1);
});

test("wsl readFile reads a home-relative path", async () => {
  let command = "";
  const shell = makeWslShell({ platform: "win32", exec: async (_command, args) => { command = args.join(" "); return { stdout: "{}" }; } });
  assert.equal(await shell.readFile("Ubuntu", ".codex/auth.json"), "{}");
  assert.match(command, /cat "\$HOME\/\.codex\/auth\.json"/);
});

test("wsl newestJsonl returns the home-relative newest session", async () => {
  const shell = makeWslShell({ platform: "win32", exec: async () => ({ stdout: ".codex/sessions/2025/06/abc.jsonl\n" }) });
  assert.equal(await shell.newestJsonl("Ubuntu", ".codex/sessions"), ".codex/sessions/2025/06/abc.jsonl");
});

test("wsl newestJsonl returns undefined when empty", async () => {
  const shell = makeWslShell({ platform: "win32", exec: async () => ({ stdout: "" }) });
  assert.equal(await shell.newestJsonl("Ubuntu", ".codex/sessions"), undefined);
});
