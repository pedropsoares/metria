import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readCursorItem } from "../main/cursor-state";

/** Builds the two-column `ItemTable` Cursor's `state.vscdb` uses. */
function fixture(rows: [string, string][]): { path: string; cleanup: () => void } {
  const directory = mkdtempSync(join(tmpdir(), "metria-cursor-test-"));
  const path = join(directory, "state.vscdb");
  const database = new DatabaseSync(path);
  database.exec("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)");
  const insert = database.prepare("INSERT INTO ItemTable (key, value) VALUES (?, ?)");
  for (const [key, value] of rows) insert.run(key, value);
  database.close();
  return { path, cleanup: () => rmSync(directory, { recursive: true, force: true }) };
}

test("readCursorItem reads the stored access token", () => {
  const { path, cleanup } = fixture([["cursorAuth/accessToken", "header.payload.signature"], ["cursorAuth/cachedEmail", "ada@example.com"]]);
  try {
    assert.equal(readCursorItem(path, "cursorAuth/accessToken"), "header.payload.signature");
  } finally { cleanup(); }
});

test("readCursorItem returns undefined for a missing key or a missing database", () => {
  const { path, cleanup } = fixture([["cursorAuth/cachedEmail", "ada@example.com"]]);
  try {
    assert.equal(readCursorItem(path, "cursorAuth/accessToken"), undefined);
    assert.equal(readCursorItem(join(path, "nope.vscdb"), "cursorAuth/accessToken"), undefined);
  } finally { cleanup(); }
});

test("readCursorItem returns undefined instead of leaking a SQLite error", () => {
  const directory = mkdtempSync(join(tmpdir(), "metria-cursor-test-"));
  const path = join(directory, "state.vscdb");
  const database = new DatabaseSync(path);
  database.exec("CREATE TABLE Unrelated (key TEXT, value TEXT)");
  database.close();
  try {
    assert.equal(readCursorItem(path, "cursorAuth/accessToken"), undefined);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
