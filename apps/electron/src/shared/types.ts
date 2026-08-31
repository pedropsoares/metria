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
  phoneSyncEnabled: boolean;
  displayMode: "tray" | "notch";
  notchPinned: boolean;
}

export interface CardShowPayload {
  index: number;
  kind: ProviderKind;
}

export interface RailStatePayload {
  collapsed: boolean;
}

export interface MetriaApi {
  getUsage(): Promise<ProviderUsage[]>;
  refresh(): Promise<ProviderUsage[]>;
  getSettings(): Promise<AppSettings>;
  setProviderEnabled(kind: ProviderKind, enabled: boolean): Promise<AppSettings>;
  reconnect(kind: ProviderKind): Promise<{ command: string; message: string }>;
  getPairingStatus(): Promise<PairingStatus>;
  setPhoneSyncEnabled(enabled: boolean): Promise<AppSettings>;
  setDisplayMode(mode: "tray" | "notch"): Promise<AppSettings>;
  setNotchPinned(pinned: boolean): Promise<AppSettings>;
  getPairingQRCode(): Promise<string>;
  getLoginItemStatus(): Promise<LoginItemStatus>;
  setLaunchAtLogin(enabled: boolean): Promise<LoginItemStatus>;
  getPairingLink(): Promise<string>;
  regeneratePairing(): Promise<string>;
  setRailHovered(hovered: boolean): Promise<void>;
  setProviderHover(providerIndex: number | null): Promise<void>;
  openDashboard(): Promise<void>;
  resizeCard(height: number): Promise<void>;
  onCardShow(callback: (payload: CardShowPayload) => void): void;
  onCardHide(callback: () => void): void;
  onRailState(callback: (state: RailStatePayload) => void): void;
}

export interface PairingStatus { enabled: boolean; secureStorage: "available" | "unavailable"; message: string; }
export interface LoginItemStatus { available: boolean; enabled: boolean; message: string; }
