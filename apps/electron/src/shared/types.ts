export type ProviderKind = "Claude" | "Codex" | "OpenCode Go";

export interface UsageWindow {
  title: string;
  percent: number;
  resetDate: string | null;
}

export interface ProviderUsage {
  kind: ProviderKind;
  windows: UsageWindow[];
  updatedAt: string | null;
  error: string | null;
  available: boolean;
  setupHint: string;
}

export interface AppSettings {
  refreshIntervalSeconds: number;
  enabledProviders: ProviderKind[];
  widgetYOffset: number;
  providerSource: Partial<Record<ProviderKind, ProviderSourceChoice>>;
}

export interface CardShowPayload {
  index: number;
  kind: ProviderKind;
}

export interface MetriaApi {
  getUsage(): Promise<ProviderUsage[]>;
  refresh(): Promise<ProviderUsage[]>;
  getSettings(): Promise<AppSettings>;
  openDashboard(): Promise<void>;
  setProviderHover(index: number | null): Promise<void>;
  resizeCard(height: number): Promise<void>;
  onSettingsChanged(callback: () => void): void;
  onCardShow(callback: (payload: CardShowPayload) => void): void;
  onCardHide(callback: () => void): void;
  setProviderEnabled(kind: ProviderKind, enabled: boolean): Promise<AppSettings>;
  reconnect(kind: ProviderKind): Promise<{ command: string; message: string }>;
  setWidgetYOffset(offsetY: number): Promise<AppSettings>;
  getLoginItemStatus(): Promise<LoginItemStatus>;
  setLaunchAtLogin(enabled: boolean): Promise<LoginItemStatus>;
  getAppInfo(): Promise<AppInfo>;
  checkUpdates(): Promise<UpdateCheckResult>;
  installUpdate(): Promise<void>;
  uninstall(): Promise<UninstallResult>;
  quit(): Promise<void>;
  setRefreshInterval(seconds: number): Promise<AppSettings>;
  getProviderSources(): Promise<ProviderSourceInfo[]>;
  setProviderSource(kind: ProviderKind, source: ProviderSourceChoice): Promise<AppSettings>;
}

export interface LoginItemStatus { available: boolean; enabled: boolean; message: string; }

export interface AppInfo {
  version: string;
  platform: string;
  packaged: boolean;
  dataPath: string;
}

export interface UpdateCheckResult {
  status: "up-to-date" | "downloaded" | "unavailable" | "error";
  message: string;
}

export interface UninstallResult {
  opened: boolean;
  message: string;
}

export interface ProviderSourceChoice {
  location: "host" | "wsl";
  distro?: string;
}

export interface WslPresence {
  distro: string;
  present: boolean;
}

export interface ProviderSourceInfo {
  kind: ProviderKind;
  host: boolean;
  wsl: WslPresence[];
  source: ProviderSourceChoice | null;
  needsChoice: boolean;
}

export const ALL_PROVIDER_KINDS: ProviderKind[] = ["Claude", "Codex", "OpenCode Go"];

export function isProviderKind(value: unknown): value is ProviderKind {
  return value === "Claude" || value === "Codex" || value === "OpenCode Go";
}

export const PROVIDER_LOGOS: Record<ProviderKind, string> = {
  "Claude": "claude-logo.png",
  "Codex": "codex-logo.png",
  "OpenCode Go": "opencode-logo.png"
};

export function providerShortLabel(kind: ProviderKind): string {
  return kind === "OpenCode Go" ? "Go" : kind;
}

export function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}

export function gaugeColor(percent: number): string {
  return percent >= 85 ? "#ff453a" : percent >= 65 ? "#ff9f0a" : percent >= 40 ? "#ffd60a" : "#30d158";
}

export function statusDotColor(hasError: boolean): string {
  return hasError ? "#ff9f0a" : "#30d158";
}

export const WIDGET_ITEM_HEIGHT = 52;
export const CARD_WIDTH = 316;
export const DEFAULT_WIDGET_Y_OFFSET = 12;
export const DEFAULT_REFRESH_INTERVAL_SECONDS = 300;
export const PRESENCE_CACHE_TTL_MS = 30_000;
