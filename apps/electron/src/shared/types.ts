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
}

export interface LoginItemStatus { available: boolean; enabled: boolean; message: string; }
