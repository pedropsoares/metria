import { copyFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

/** Minimal shape of `node:sqlite`, declared locally so the module stays a lazy
 * runtime dependency: it is still marked experimental, and no user without
 * Cursor installed should pay for loading it. */
interface StatementSyncLike { get(...parameters: unknown[]): unknown }
interface DatabaseSyncLike { prepare(sql: string): StatementSyncLike; close(): void }
type DatabaseSyncConstructor = new (path: string, options?: { readOnly?: boolean }) => DatabaseSyncLike;

let databaseSyncCache: { constructor: DatabaseSyncConstructor | undefined } | undefined;

function databaseSync(): DatabaseSyncConstructor | undefined {
  if (!databaseSyncCache) {
    try {
      databaseSyncCache = { constructor: (require("node:sqlite") as { DatabaseSync?: DatabaseSyncConstructor }).DatabaseSync };
    } catch {
      databaseSyncCache = { constructor: undefined };
    }
  }
  return databaseSyncCache.constructor;
}

/** Read one `ItemTable(key, value)` row from a VS Code-derivative `state.vscdb`.
 * Returns `undefined` for every failure mode — missing runtime, missing file,
 * missing table, missing key, unreadable value — so callers can report one
 * clear message instead of leaking SQLite errors into a usage card. */
export function readCursorItem(path: string, key: string): string | undefined {
  const DatabaseSync = databaseSync();
  if (!DatabaseSync || !existsSync(path)) return undefined;
  return readFrom(DatabaseSync, path, key, { readOnly: true }) ?? readFromCopy(DatabaseSync, path, key);
}

function readFrom(DatabaseSync: DatabaseSyncConstructor, path: string, key: string, options?: { readOnly?: boolean }): string | undefined {
  let database: DatabaseSyncLike | undefined;
  try {
    database = new DatabaseSync(path, options);
    const row = database.prepare("SELECT value FROM ItemTable WHERE key = ? LIMIT 1").get(key);
    return decodeValue((row as { value?: unknown } | undefined)?.value);
  } catch {
    return undefined;
  } finally {
    try { database?.close(); } catch { /* Closing a failed open is not an error worth reporting. */ }
  }
}

/** Cursor keeps the database open with a write-ahead log, and a read-only handle
 * cannot replay a WAL that still needs recovery. Reading a private copy — which
 * may be opened for writing because it is ours — keeps the live file untouched. */
function readFromCopy(DatabaseSync: DatabaseSyncConstructor, path: string, key: string): string | undefined {
  let directory: string | undefined;
  try {
    directory = mkdtempSync(join(tmpdir(), "metria-cursor-"));
    const copy = join(directory, basename(path));
    copyFileSync(path, copy);
    for (const suffix of ["-wal", "-shm"]) {
      if (existsSync(`${path}${suffix}`)) copyFileSync(`${path}${suffix}`, `${copy}${suffix}`);
    }
    return readFrom(DatabaseSync, copy, key);
  } catch {
    return undefined;
  } finally {
    if (directory) { try { rmSync(directory, { recursive: true, force: true }); } catch { /* Temporary directory cleanup is best effort. */ } }
  }
}

function decodeValue(value: unknown): string | undefined {
  if (typeof value === "string") return value || undefined;
  if (value instanceof Uint8Array) return Buffer.from(value).toString("utf8") || undefined;
  return undefined;
}
