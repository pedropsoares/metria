import { app } from "electron";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { AppSettings, ProviderKind } from "../shared/types";

const defaults: AppSettings = {
  refreshIntervalSeconds: 300,
  enabledProviders: ["Claude", "Codex", "OpenCode Go"],
  phoneSyncEnabled: false,
  displayMode: "tray",
  notchPinned: true
};

export class SettingsStore {
  private readonly path = join(app.getPath("userData"), "settings.json");

  load(): AppSettings {
    try {
      const parsed = JSON.parse(readFileSync(this.path, "utf8")) as Partial<AppSettings>;
      return {
        refreshIntervalSeconds: Number.isFinite(parsed.refreshIntervalSeconds) ? Math.max(60, Number(parsed.refreshIntervalSeconds)) : defaults.refreshIntervalSeconds,
        enabledProviders: Array.isArray(parsed.enabledProviders) ? parsed.enabledProviders.filter(isProviderKind) : defaults.enabledProviders,
        phoneSyncEnabled: parsed.phoneSyncEnabled === true,
        displayMode: parsed.displayMode === "notch" ? "notch" : "tray",
        notchPinned: parsed.notchPinned === true
      };
    } catch { return defaults; }
  }

  setPhoneSyncEnabled(phoneSyncEnabled: boolean): AppSettings { return this.save({ ...this.load(), phoneSyncEnabled }); }
  setDisplayMode(displayMode: AppSettings["displayMode"]): AppSettings { return this.save({ ...this.load(), displayMode }); }
  setNotchPinned(notchPinned: boolean): AppSettings { return this.save({ ...this.load(), notchPinned }); }

  private save(next: AppSettings): AppSettings {
    mkdirSync(dirname(this.path), { recursive: true });
    const temporaryPath = `${this.path}.tmp`;
    writeFileSync(temporaryPath, JSON.stringify(next, null, 2), { mode: 0o600 });
    renameSync(temporaryPath, this.path);
    return next;
  }

  setProviderEnabled(kind: ProviderKind, enabled: boolean): AppSettings {
    const current = this.load();
    const enabledProviders = enabled
      ? [...new Set([...current.enabledProviders, kind])]
      : current.enabledProviders.filter((candidate) => candidate !== kind);
    const next = { ...current, enabledProviders };
    return this.save(next);
  }
}

function isProviderKind(value: unknown): value is ProviderKind {
  return value === "Claude" || value === "Codex" || value === "OpenCode Go";
}
