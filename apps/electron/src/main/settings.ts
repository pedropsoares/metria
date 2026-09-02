import { app } from "electron";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { ALL_PROVIDER_KINDS, DEFAULT_LOCAL_SERVER_PORT, DEFAULT_NTFY_SERVER, DEFAULT_PWA_URL, DEFAULT_REFRESH_INTERVAL_SECONDS, DEFAULT_WIDGET_Y_OFFSET, isProviderKind } from "../shared/types";
import type { AppSettings, ProviderKind, ProviderSourceChoice } from "../shared/types";

const defaults: AppSettings = {
  refreshIntervalSeconds: DEFAULT_REFRESH_INTERVAL_SECONDS,
  enabledProviders: [...ALL_PROVIDER_KINDS],
  widgetYOffset: DEFAULT_WIDGET_Y_OFFSET,
  providerSource: {},
  ntfyServer: DEFAULT_NTFY_SERVER,
  localServerPort: DEFAULT_LOCAL_SERVER_PORT,
  customPwaUrl: DEFAULT_PWA_URL
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
        providerSource: normalizeProviderSource(parsed.providerSource),
        ntfyServer: normalizeNtfyServer(parsed.ntfyServer),
        localServerPort: normalizePort(parsed.localServerPort),
        customPwaUrl: normalizePwaUrl(parsed.customPwaUrl)
      };
    } catch { return defaults; }
  }

  setWidgetYOffset(widgetYOffset: number): AppSettings { return this.save({ ...this.load(), widgetYOffset }); }

  setRefreshInterval(seconds: number): AppSettings {
    return this.save({ ...this.load(), refreshIntervalSeconds: Math.max(60, Math.round(seconds)) });
  }

  setNtfyServer(server: string): AppSettings { return this.save({ ...this.load(), ntfyServer: normalizeNtfyServer(server) }); }

  setLocalServerPort(port: number): AppSettings { return this.save({ ...this.load(), localServerPort: normalizePort(port) }); }

  setCustomPwaUrl(url: string): AppSettings { return this.save({ ...this.load(), customPwaUrl: normalizePwaUrl(url) }); }

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

function normalizeProviderSource(value: unknown): Partial<Record<ProviderKind, ProviderSourceChoice>> {
  if (typeof value !== "object" || value === null) return {};
  const source = value as Record<string, unknown>;
  const normalized: Partial<Record<ProviderKind, ProviderSourceChoice>> = {};
  ALL_PROVIDER_KINDS.forEach((kind) => {
    const entry = source[kind];
    if (typeof entry !== "object" || entry === null) return;
    const candidate = entry as Record<string, unknown>;
    if (candidate.location === "host") normalized[kind] = { location: "host" };
    else if (candidate.location === "wsl" && typeof candidate.distro === "string" && candidate.distro.length > 0) normalized[kind] = { location: "wsl", distro: candidate.distro };
  });
  return normalized;
}

/** Only HTTPS relays are accepted: the snapshot body is encrypted, but the topic name
 * would otherwise travel in the clear. */
function normalizeNtfyServer(value: unknown): string {
  if (typeof value !== "string") return DEFAULT_NTFY_SERVER;
  const trimmed = value.trim();
  try {
    const url = new URL(trimmed);
    return url.protocol === "https:" ? trimmed.replace(/\/+$/, "") : DEFAULT_NTFY_SERVER;
  } catch {
    return DEFAULT_NTFY_SERVER;
  }
}

function normalizePort(value: unknown): number {
  const port = Number(value);
  return Number.isInteger(port) && port > 0 && port <= 65_535 ? port : DEFAULT_LOCAL_SERVER_PORT;
}

/** An empty URL is meaningful: it pairs the phone through this machine's LAN server
 * instead of a hosted deployment. Anything that is not HTTPS falls back to the default. */
function normalizePwaUrl(value: unknown): string {
  if (typeof value !== "string") return DEFAULT_PWA_URL;
  const trimmed = value.trim();
  if (trimmed.length === 0) return "";
  try {
    const url = new URL(trimmed);
    return url.protocol === "https:" ? trimmed.replace(/\/+$/, "") : DEFAULT_PWA_URL;
  } catch {
    return DEFAULT_PWA_URL;
  }
}
