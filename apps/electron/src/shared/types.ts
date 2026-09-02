export type ProviderKind = "Claude" | "Codex" | "OpenCode Go" | "Cursor";

export interface UsageWindow {
  title: string;
  percent: number;
  resetDate: string | null;
  /** What the window costs, in cents, when the provider measures money rather than a
   * bare percentage (Cursor). Present as a pair or not at all. */
  usedCents?: number;
  limitCents?: number;
}

/** How a window carrying spend amounts prints its magnitude. */
export type SpendDisplay = "percent" | "dollars" | "both";

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
  spendDisplay: SpendDisplay;
  enabledProviders: ProviderKind[];
  widgetYOffset: number;
  providerSource: Partial<Record<ProviderKind, ProviderSourceChoice>>;
  ntfyServer: string;
  localServerPort: number;
  customPwaUrl: string;
}

/** Everything the dashboard needs to show the pairing pane: the QR code and phrase a
 * phone pairs with, plus the addresses that code points at. */
export interface PairingInfo {
  words: string[];
  link: string;
  qrDataUrl: string;
  localUrl: string | null;
  ntfyServer: string;
  localServerPort: number;
  customPwaUrl: string;
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
  setSpendDisplay(display: SpendDisplay): Promise<AppSettings>;
  getProviderSources(): Promise<ProviderSourceInfo[]>;
  setProviderSource(kind: ProviderKind, source: ProviderSourceChoice): Promise<AppSettings>;
  getPairing(): Promise<PairingInfo>;
  regeneratePairing(): Promise<PairingInfo>;
  setNtfyServer(server: string): Promise<PairingInfo>;
  setLocalServerPort(port: number): Promise<PairingInfo>;
  setCustomPwaUrl(url: string): Promise<PairingInfo>;
  copyText(text: string): Promise<void>;
  onPairingChanged(callback: () => void): void;
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

export const ALL_PROVIDER_KINDS: ProviderKind[] = ["Claude", "Codex", "OpenCode Go", "Cursor"];

export function isProviderKind(value: unknown): value is ProviderKind {
  return value === "Claude" || value === "Codex" || value === "OpenCode Go" || value === "Cursor";
}

export const PROVIDER_LOGOS: Record<ProviderKind, string> = {
  "Claude": "claude-logo.png",
  "Codex": "codex-logo.png",
  "OpenCode Go": "opencode-logo.png",
  "Cursor": "cursor-logo.png"
};

export function providerShortLabel(kind: ProviderKind): string {
  return kind === "OpenCode Go" ? "Go" : kind;
}

export function isSpendDisplay(value: unknown): value is SpendDisplay {
  return value === "percent" || value === "dollars" || value === "both";
}

/** Cursor reports cents. Whole dollars drop the decimals so the common case reads as
 * money ("$130") instead of accounting ("$130.00"). */
export function formatCents(cents: number): string {
  const dollars = cents / 100;
  return `$${Number.isInteger(dollars) ? dollars.toFixed(0) : dollars.toFixed(2)}`;
}

/** The money half of a window's readout — "$130 / $250" — or null for a provider that
 * only ever reports a percentage. */
export function spendText(window: UsageWindow): string | null {
  return typeof window.usedCents === "number" && typeof window.limitCents === "number"
    ? `${formatCents(window.usedCents)} / ${formatCents(window.limitCents)}`
    : null;
}

/** Which halves of the readout a window shows. A window without amounts always keeps its
 * percentage, so choosing "dollars" never blanks out Claude, Codex, or OpenCode Go. */
export function usageParts(window: UsageWindow, display: SpendDisplay): { percent: boolean; spend: string | null } {
  const spend = spendText(window);
  if (!spend) return { percent: true, spend: null };
  return { percent: display !== "dollars", spend: display === "percent" ? null : spend };
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
export const DEFAULT_SPEND_DISPLAY: SpendDisplay = "both";
export const DEFAULT_NTFY_SERVER = "https://ntfy.sh";
export const DEFAULT_LOCAL_SERVER_PORT = 8973;
/** The hosted PWA the native app pairs against by default; an empty setting pairs
 * through this machine's own LAN server instead. */
export const DEFAULT_PWA_URL = "https://metria-pwa.yuriramos2406.workers.dev";
export const PRESENCE_CACHE_TTL_MS = 30_000;
