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
  /** The signed-in account: an email where the provider exposes one, a masked key for
   * OpenCode Go, and null when the credentials carry neither. */
  accountLabel: string | null;
  windows: UsageWindow[];
  updatedAt: string | null;
  error: string | null;
  available: boolean;
  setupHint: string;
}

export interface AppSettings {
  refreshIntervalSeconds: number;
  spendDisplay: SpendDisplay;
  showAccountLabels: boolean;
  /** Usage windows the dashboard and card leave out, per provider, by title. */
  hiddenWindows: Partial<Record<ProviderKind, string[]>>;
  enabledProviders: ProviderKind[];
  widgetYOffset: number;
  widgetSize: WidgetSize;
  widgetEdge: WidgetEdge;
  widgetBehavior: WidgetBehavior;
  /** Which display the widget lives on; null follows the display under the pointer. */
  widgetDisplayId: number | null;
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
  setShowAccountLabels(show: boolean): Promise<AppSettings>;
  setWindowHidden(kind: ProviderKind, title: string, hidden: boolean): Promise<AppSettings>;
  setWidgetSize(size: WidgetSize): Promise<AppSettings>;
  setWidgetEdge(edge: WidgetEdge): Promise<AppSettings>;
  setWidgetBehavior(behavior: WidgetBehavior): Promise<AppSettings>;
  setWidgetDisplay(displayId: number | null): Promise<AppSettings>;
  getDisplays(): Promise<DisplayInfo[]>;
  setWidgetHover(hovering: boolean): Promise<void>;
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

export interface DisplayInfo {
  id: number;
  label: string;
  primary: boolean;
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

/** The widget's three sizes, and everything the main process and the renderer each need
 * to lay one out: the window is sized from these, and the rail draws itself to match. */
export type WidgetSize = "compact" | "regular" | "large";
export type WidgetEdge = "left" | "right";
/** "always" keeps the rail on screen; "hover" collapses it to a sliver against the screen
 * edge until the pointer reaches it. */
export type WidgetBehavior = "always" | "hover";

export interface WidgetMetrics { width: number; itemHeight: number; ring: number; gap: number; padding: number; }

export const WIDGET_METRICS: Record<WidgetSize, WidgetMetrics> = {
  compact: { width: 68, itemHeight: 42, ring: 30, gap: 6, padding: 10 },
  regular: { width: 88, itemHeight: 52, ring: 38, gap: 8, padding: 12 },
  large: { width: 112, itemHeight: 66, ring: 50, gap: 10, padding: 14 }
};

/** How wide the collapsed rail stays: enough to be a hover target and to show which edge
 * it is docked to, narrow enough to stay out of the way. */
export const WIDGET_COLLAPSED_WIDTH = 10;

export function isWidgetSize(value: unknown): value is WidgetSize {
  return value === "compact" || value === "regular" || value === "large";
}
export function isWidgetEdge(value: unknown): value is WidgetEdge {
  return value === "left" || value === "right";
}
export function isWidgetBehavior(value: unknown): value is WidgetBehavior {
  return value === "always" || value === "hover";
}

/** The windows a surface should draw for a provider, with the ones hidden in Settings
 * left out. */
export function visibleWindows(provider: ProviderUsage, hidden: AppSettings["hiddenWindows"]): UsageWindow[] {
  const titles = hidden[provider.kind] ?? [];
  return provider.windows.filter((row) => !titles.includes(row.title));
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

export const CARD_WIDTH = 316;
export const DEFAULT_WIDGET_Y_OFFSET = 12;
export const DEFAULT_REFRESH_INTERVAL_SECONDS = 300;
export const DEFAULT_SPEND_DISPLAY: SpendDisplay = "both";
export const DEFAULT_WIDGET_SIZE: WidgetSize = "regular";
export const DEFAULT_WIDGET_EDGE: WidgetEdge = "right";
export const DEFAULT_WIDGET_BEHAVIOR: WidgetBehavior = "always";
export const DEFAULT_NTFY_SERVER = "https://ntfy.sh";
export const DEFAULT_LOCAL_SERVER_PORT = 8973;
/** The hosted PWA the native app pairs against by default; an empty setting pairs
 * through this machine's own LAN server instead. */
export const DEFAULT_PWA_URL = "https://metria-pwa.yuriramos2406.workers.dev";
export const PRESENCE_CACHE_TTL_MS = 30_000;
