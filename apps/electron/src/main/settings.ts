import { app } from "electron";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { AppSettings, ProviderKind, ProviderSourceChoice } from "../shared/types";

const defaults: AppSettings = {
  refreshIntervalSeconds: 300,
  enabledProviders: ["Claude", "Codex", "OpenCode Go"],
  widgetYOffset: 12,
  providerSource: {}
};

export class SettingsStore {
  private readonly path = join(app.getPath("userData"), "settings.json");

  load(): AppSettings {
    try {
      const parsed = JSON.parse(readFileSync(this.path, "utf8")) as Partial<AppSettings>;
      return {
        refreshIntervalSeconds: Number.isFinite(parsed.refreshIntervalSeconds) ? Math.max(60, Number(parsed.refreshIntervalSeconds)) : defaults.refreshIntervalSeconds,
        enabledProviders: Array.isArray(parsed.enabledProviders) ? parsed.enabledProviders.filter(isProviderKind) : defaults.enabledProviders,
        widgetYOffset: Number.isFinite(parsed.widgetYOffset) && Number(parsed.widgetYOffset) >= 0 ? Number(parsed.widgetYOffset) : defaults.widgetYOffset,
        providerSource: normalizeProviderSource(parsed.providerSource)
      };
    } catch { return defaults; }
  }

  setWidgetYOffset(widgetYOffset: number): AppSettings { return this.save({ ...this.load(), widgetYOffset }); }

  setRefreshInterval(seconds: number): AppSettings {
    return this.save({ ...this.load(), refreshIntervalSeconds: Math.max(60, Math.round(seconds)) });
  }

  setProviderSource(kind: ProviderKind, source: ProviderSourceChoice): AppSettings {
    const current = this.load();
    return this.save({ ...current, providerSource: { ...current.providerSource, [kind]: source } });
  }

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

function normalizeProviderSource(value: unknown): Partial<Record<ProviderKind, ProviderSourceChoice>> {
  if (typeof value !== "object" || value === null) return {};
  const source = value as Record<string, unknown>;
  const normalized: Partial<Record<ProviderKind, ProviderSourceChoice>> = {};
  (["Claude", "Codex", "OpenCode Go"] as ProviderKind[]).forEach((kind) => {
    const entry = source[kind];
    if (typeof entry !== "object" || entry === null) return;
    const candidate = entry as Record<string, unknown>;
    if (candidate.location === "host") normalized[kind] = { location: "host" };
    else if (candidate.location === "wsl" && typeof candidate.distro === "string" && candidate.distro.length > 0) normalized[kind] = { location: "wsl", distro: candidate.distro };
  });
  return normalized;
}
