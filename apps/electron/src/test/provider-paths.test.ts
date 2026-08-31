import test from "node:test";
import assert from "node:assert/strict";
import { providerPaths } from "../main/provider-paths";

test("provider credential roots honor Windows, Linux XDG, and explicit Codex home", () => {
  assert.equal(providerPaths({ platform: "win32", home: "C:\\Users\\Ada", env: { APPDATA: "C:\\Users\\Ada\\AppData\\Roaming" } }).openCodeAuth, "C:\\Users\\Ada\\AppData\\Roaming/opencode/auth.json");
  assert.equal(providerPaths({ platform: "linux", home: "/home/ada", env: { XDG_DATA_HOME: "/data" } }).openCodeAuth, "/data/opencode/auth.json");
  assert.equal(providerPaths({ platform: "linux", home: "/home/ada", env: { CODEX_HOME: "/portable/codex" } }).codexSessions, "/portable/codex/sessions");
});
