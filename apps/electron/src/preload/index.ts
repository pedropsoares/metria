import { contextBridge, ipcRenderer } from "electron";
import type { CardShowPayload, MetriaApi, ProviderKind, ProviderSourceChoice } from "../shared/types";

const api: MetriaApi = {
  getUsage: () => ipcRenderer.invoke("metria:get-usage"),
  refresh: () => ipcRenderer.invoke("metria:refresh"),
  openDashboard: () => ipcRenderer.invoke("metria:open-dashboard"),
  setProviderHover: (index: number | null) => ipcRenderer.invoke("metria:provider-hover", index),
  resizeCard: (height: number) => ipcRenderer.invoke("metria:card-resize", height),
  onSettingsChanged: (callback: () => void) => { ipcRenderer.on("metria:settings-changed", () => callback()); },
  onCardShow: (callback: (payload: CardShowPayload) => void) => { ipcRenderer.on("metria:card-show", (_event, payload: CardShowPayload) => callback(payload)); },
  onCardHide: (callback: () => void) => { ipcRenderer.on("metria:card-hide", () => callback()); },
  getSettings: () => ipcRenderer.invoke("metria:get-settings"),
  setProviderEnabled: (kind: ProviderKind, enabled: boolean) => ipcRenderer.invoke("metria:set-provider-enabled", kind, enabled),
  reconnect: (kind: ProviderKind) => ipcRenderer.invoke("metria:reconnect", kind),
  setWidgetYOffset: (offsetY: number) => ipcRenderer.invoke("metria:set-widget-y-offset", offsetY),
  getLoginItemStatus: () => ipcRenderer.invoke("metria:get-login-item-status"),
  setLaunchAtLogin: (enabled: boolean) => ipcRenderer.invoke("metria:set-launch-at-login", enabled),
  getAppInfo: () => ipcRenderer.invoke("metria:app-info"),
  checkUpdates: () => ipcRenderer.invoke("metria:check-updates"),
  installUpdate: () => ipcRenderer.invoke("metria:install-update"),
  uninstall: () => ipcRenderer.invoke("metria:uninstall"),
  quit: () => ipcRenderer.invoke("metria:quit"),
  setRefreshInterval: (seconds: number) => ipcRenderer.invoke("metria:set-refresh-interval", seconds),
  getProviderSources: () => ipcRenderer.invoke("metria:get-provider-sources"),
  setProviderSource: (kind: ProviderKind, source: ProviderSourceChoice) => ipcRenderer.invoke("metria:set-provider-source", kind, source)
};

contextBridge.exposeInMainWorld("metria", Object.freeze(api));
