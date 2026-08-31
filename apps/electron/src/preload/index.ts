import { contextBridge, ipcRenderer } from "electron";
import type { CardShowPayload, MetriaApi, ProviderKind, RailStatePayload } from "../shared/types";

const api: MetriaApi = {
  getUsage: () => ipcRenderer.invoke("metria:get-usage"),
  refresh: () => ipcRenderer.invoke("metria:refresh"),
  getSettings: () => ipcRenderer.invoke("metria:get-settings"),
  setProviderEnabled: (kind: ProviderKind, enabled: boolean) => ipcRenderer.invoke("metria:set-provider-enabled", kind, enabled),
  reconnect: (kind: ProviderKind) => ipcRenderer.invoke("metria:reconnect", kind),
  getPairingStatus: () => ipcRenderer.invoke("metria:get-pairing-status"),
  setPhoneSyncEnabled: (enabled: boolean) => ipcRenderer.invoke("metria:set-phone-sync-enabled", enabled),
  setDisplayMode: (mode: "tray" | "notch") => ipcRenderer.invoke("metria:set-display-mode", mode),
  setNotchPinned: (pinned: boolean) => ipcRenderer.invoke("metria:set-notch-pinned", pinned),
  getPairingLink: () => ipcRenderer.invoke("metria:get-pairing-link"),
  getPairingQRCode: () => ipcRenderer.invoke("metria:get-pairing-qr"),
  getLoginItemStatus: () => ipcRenderer.invoke("metria:get-login-item-status"),
  setLaunchAtLogin: (enabled: boolean) => ipcRenderer.invoke("metria:set-launch-at-login", enabled),
  regeneratePairing: () => ipcRenderer.invoke("metria:regenerate-pairing"),
  setRailHovered: (hovered: boolean) => ipcRenderer.invoke("metria:rail-hover", hovered),
  setProviderHover: (providerIndex: number | null) => ipcRenderer.invoke("metria:provider-hover", providerIndex),
  openDashboard: () => ipcRenderer.invoke("metria:open-dashboard"),
  resizeCard: (height: number) => ipcRenderer.invoke("metria:card-resize", height),
  onCardShow: (callback: (payload: CardShowPayload) => void) => { ipcRenderer.on("metria:card-show", (_event, payload: CardShowPayload) => callback(payload)); },
  onCardHide: (callback: () => void) => { ipcRenderer.on("metria:card-hide", () => callback()); },
  onRailState: (callback: (state: RailStatePayload) => void) => { ipcRenderer.on("metria:rail-state", (_event, state: RailStatePayload) => callback(state)); }
};

contextBridge.exposeInMainWorld("metria", Object.freeze(api));
