import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { providerPaths } from "../main/provider-paths";

test("provider credential roots honor Windows, Linux XDG, and explicit Codex home", () => {
  const win = { platform: "win32", home: "C:\\Users\\Ada", env: { APPDATA: "C:\\Users\\Ada\\AppData\\Roaming" } } as const;
  const linux = { platform: "linux", home: "/home/ada", env: {} } as const;
  assert.equal(providerPaths(win).openCodeAuth, join("C:\\Users\\Ada\\AppData\\Roaming", "opencode", "auth.json"));
  assert.equal(providerPaths(linux).openCodeAuth, join("/home/ada", ".local", "share", "opencode", "auth.json"));
  assert.equal(providerPaths({ ...linux, env: { XDG_DATA_HOME: "/data" } }).openCodeAuth, join("/data", "opencode", "auth.json"));
  assert.equal(providerPaths({ ...linux, env: { CODEX_HOME: "/portable/codex" } }).codexSessions, join("/portable/codex", "sessions"));
  assert.equal(providerPaths(win).claudeCredentials, join("C:\\Users\\Ada", ".claude", ".credentials.json"));
  assert.equal(providerPaths(linux).claudeCredentials, join("/home/ada", ".claude", ".credentials.json"));
});

test("Cursor state database follows the config root, not the data root", () => {
  const win = { platform: "win32", home: "C:\\Users\\Ada", env: { APPDATA: "C:\\Users\\Ada\\AppData\\Roaming" } } as const;
  const linux = { platform: "linux", home: "/home/ada", env: {} } as const;
  const mac = { platform: "darwin", home: "/Users/ada", env: {} } as const;
  const suffix = join("Cursor", "User", "globalStorage", "state.vscdb");
  assert.equal(providerPaths(win).cursorState, join("C:\\Users\\Ada\\AppData\\Roaming", suffix));
  assert.equal(providerPaths(linux).cursorState, join("/home/ada", ".config", suffix));
  assert.equal(providerPaths({ ...linux, env: { XDG_CONFIG_HOME: "/config" } }).cursorState, join("/config", suffix));
  assert.equal(providerPaths({ ...linux, env: { XDG_DATA_HOME: "/data" } }).cursorState, join("/home/ada", ".config", suffix));
  assert.equal(providerPaths(mac).cursorState, join("/Users/ada", "Library", "Application Support", suffix));
});
