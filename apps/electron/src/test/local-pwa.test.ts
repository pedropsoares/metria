import test from "node:test";
import assert from "node:assert/strict";
import { staticPath } from "../main/local-pwa";

test("static PWA paths stay inside their configured root", () => {
  const root = "/tmp/metria-pwa";
  assert.equal(staticPath(root, "/index.html"), "/tmp/metria-pwa/index.html");
  assert.equal(staticPath(root, "/%2e%2e/secret"), undefined);
  assert.equal(staticPath(root, "/assets/../../secret"), undefined);
  assert.equal(staticPath(root, "/bad%ZZ"), undefined);
});
