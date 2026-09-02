import { app } from "electron";
import { existsSync } from "node:fs";
import { join } from "node:path";

/**
 * Locates a bundled asset: the shared logos plus the PWA files the local server hands to
 * a paired phone. Packaged builds get them from `extraResources`; development reads them
 * straight out of the repository.
 */
export function findResource(name: string): string | undefined {
  const candidates = app.isPackaged
    ? [join(process.resourcesPath, "MetriaPWA", name)]
    : [join(app.getAppPath(), "..", "..", "Assets", name), join(app.getAppPath(), "..", "pwa", "public", name)];
  return candidates.find((candidate) => existsSync(candidate));
}
