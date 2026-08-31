import { app, BrowserWindow, ipcMain, Menu, nativeImage, screen, shell, Tray } from "electron";
import { Server } from "node:http";
import { join } from "node:path";
import { existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { ProviderService } from "./providers";
import { SettingsStore } from "./settings";
import type { ProviderKind } from "../shared/types";
import { encryptedSnapshot, PairingStore, shouldPublish } from "./pairing";
import { startLocalPWA } from "./local-pwa";
import { cardBounds, estimateCardHeight, NOTCH, railBounds } from "./display";
import QRCode from "qrcode";

let window: BrowserWindow | undefined;
let notchWindow: BrowserWindow | undefined;
let cardWindow: BrowserWindow | undefined;
let tray: Tray | undefined;
let refreshTimer: NodeJS.Timeout | undefined;
let isQuitting = false;
let localServer: Server | undefined;
let pairingSecret: Buffer | undefined;
let latestSnapshot = Buffer.from("{}", "utf8");
let lastUsage: Awaited<ReturnType<ProviderService["fetch"]>> = [];
let railHovered = false;
let cardActiveIndex: number | null = null;
let activeCardKind: ProviderKind | null = null;
let pendingCardHide: NodeJS.Timeout | undefined;
const pairingFile = join(app.getPath("userData"), "pairing.secret");
const settings = new SettingsStore();
const providers = new ProviderService();
const pairing = new PairingStore(pairingFile);

function createWindow(): BrowserWindow {
  const next = new BrowserWindow({
    width: 760, height: 680, minWidth: 480, minHeight: 560, show: false,
    title: "Metria Desktop",
    backgroundColor: "#0d1117",
    webPreferences: { preload: join(__dirname, "../preload/index.js"), contextIsolation: true, sandbox: true, nodeIntegration: false, webSecurity: true }
  });
  next.removeMenu();
  next.loadFile(join(__dirname, "../renderer/index.html"));
  if (process.env.METRIA_SMOKE === "1") next.webContents.once("did-finish-load", () => {
    void next.webContents.executeJavaScript("typeof window.metria === 'object' && typeof window.metria.getUsage === 'function'")
      .then((ready) => console.log(`METRIA_SMOKE_PRELOAD=${ready}`));
  });
  next.once("ready-to-show", () => next.show());
  next.on("close", (event) => { if (!isQuitting) { event.preventDefault(); next.hide(); } });
  return next;
}

function showDashboard(): void { if (!window) window = createWindow(); window.show(); window.focus(); }

function notchArea(): Electron.Rectangle {
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
}

function railHoveredForSize(): boolean {
  return railHovered || cardActiveIndex !== null;
}

function updateRail(): void {
  if (!notchWindow) return;
  const area = notchArea();
  notchWindow.setBounds(railBounds(area, { pinned: settings.load().notchPinned, hovered: railHoveredForSize() }));
  notchWindow.webContents.send("metria:rail-state", { collapsed: !settings.load().notchPinned && !railHoveredForSize() });
}

function visibleProviders(): typeof lastUsage {
  const enabled = settings.load().enabledProviders;
  return lastUsage.filter((provider) => enabled.includes(provider.kind) && provider.available);
}

function isNotchSender(event: Electron.IpcMainInvokeEvent): boolean {
  return !!notchWindow && event.sender === notchWindow.webContents && event.senderFrame?.url === notchWindow.webContents.mainFrame.url;
}
function isCardSender(event: Electron.IpcMainInvokeEvent): boolean {
  return !!cardWindow && event.sender === cardWindow.webContents && event.senderFrame?.url === cardWindow.webContents.mainFrame.url;
}

function createCardWindow(): BrowserWindow {
  const card = new BrowserWindow({
    width: NOTCH.cardWidth, height: 200, frame: false, transparent: true, resizable: false, movable: false,
    skipTaskbar: true, alwaysOnTop: true, show: false, title: "Metria usage card",
    webPreferences: { preload: join(__dirname, "../preload/index.js"), contextIsolation: true, sandbox: true, nodeIntegration: false }
  });
  card.loadFile(join(__dirname, "../renderer/card.html"));
  card.webContents.on("did-finish-load", () => {
    if (cardActiveIndex !== null && activeCardKind) card.webContents.send("metria:card-show", { index: cardActiveIndex, kind: activeCardKind });
  });
  card.on("closed", () => { cardWindow = undefined; });
  return card;
}

function showCard(index: number, kind: ProviderKind): void {
  clearTimeout(pendingCardHide);
  const changed = cardActiveIndex !== index || activeCardKind !== kind;
  cardActiveIndex = index;
  activeCardKind = kind;
  if (!cardWindow) cardWindow = createCardWindow();
  if (changed) cardWindow.webContents.send("metria:card-show", { index, kind });
  const area = notchArea();
  const usage = lastUsage.find((candidate) => candidate.kind === kind);
  cardWindow.setBounds(cardBounds(area, index, estimateCardHeight(usage?.windows.length ?? 0)));
  cardWindow.showInactive();
  updateRail();
}

function hideCard(): void {
  cardActiveIndex = null;
  activeCardKind = null;
  cardWindow?.hide();
  updateRail();
}

function scheduleCardHide(): void {
  clearTimeout(pendingCardHide);
  pendingCardHide = setTimeout(hideCard, 200);
}

function applyDisplayMode(): void {
  const current = settings.load();
  if (current.displayMode !== "notch") {
    notchWindow?.hide();
    cardWindow?.hide();
    railHovered = false;
    cardActiveIndex = null;
    return;
  }
  const area = notchArea();
  if (!notchWindow) {
    notchWindow = new BrowserWindow({
      width: NOTCH.idleWidth, height: NOTCH.compactHeight, frame: false, transparent: true, resizable: false, movable: false,
      skipTaskbar: true, alwaysOnTop: true, title: "Metria side notch",
      webPreferences: { preload: join(__dirname, "../preload/index.js"), contextIsolation: true, sandbox: true, nodeIntegration: false }
    });
    notchWindow.loadFile(join(__dirname, "../renderer/notch.html"));
    notchWindow.webContents.on("did-finish-load", () => updateRail());
    notchWindow.on("blur", () => { railHovered = false; hideCard(); });
    notchWindow.on("closed", () => { notchWindow = undefined; });
  }
  notchWindow.setBounds(railBounds(area, { pinned: current.notchPinned, hovered: railHoveredForSize() }));
  notchWindow.webContents.send("metria:rail-state", { collapsed: !current.notchPinned && !railHoveredForSize() });
  notchWindow.showInactive();
}

interface UsageRow { name: string; percent: number; reset: string; logo: string; }
const TRAY_LOGOS: Record<ProviderKind, string> = { Claude: "claude-logo.png", Codex: "codex-logo.png", "OpenCode Go": "opencode-logo.png" };
function providerLabel(kind: ProviderKind): string { return kind === "OpenCode Go" ? "Go" : kind; }
function formatReset(resetDate: string | null): string {
  if (!resetDate) return "";
  const seconds = (new Date(resetDate).getTime() - Date.now()) / 1000;
  if (seconds > 0 && seconds < 86400) { const totalMinutes = Math.floor(seconds / 60); const hours = Math.floor(totalMinutes / 60); const minutes = totalMinutes % 60; return hours > 0 ? (minutes > 0 ? `${hours} hr ${minutes} min` : `${hours} hr`) : `${minutes} min`; }
  return new Date(resetDate).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}
function findAsset(name: string): string | undefined {
  const candidates = app.isPackaged
    ? [join(process.resourcesPath, "MetriaPWA", name)]
    : [join(app.getAppPath(), "..", "..", "Assets", name), join(app.getAppPath(), "..", "..", "MetriaPWA", name)];
  return candidates.find((candidate) => existsSync(candidate));
}
function trayMenuIcon(name: string): Electron.NativeImage | undefined {
  const path = findAsset(name);
  return path ? nativeImage.createFromPath(path).resize({ width: 16, height: 16 }) : undefined;
}
function usageRows(providers: typeof lastUsage): UsageRow[] {
  const enabled = settings.load().enabledProviders;
  return providers.filter((provider) => enabled.includes(provider.kind) && provider.windows[0]).map((provider) => ({
    name: providerLabel(provider.kind),
    percent: Math.round(Math.max(0, Math.min(100, provider.windows[0]!.percent))),
    reset: formatReset(provider.windows[0]!.resetDate),
    logo: TRAY_LOGOS[provider.kind]
  }));
}
function buildTrayMenu(rows: UsageRow[]): Menu {
  const template: Electron.MenuItemConstructorOptions[] = rows.length
    ? rows.map((row) => ({ label: `${row.name} — ${row.percent}%${row.reset ? ` · ${row.reset}` : ""}`, enabled: false, icon: trayMenuIcon(row.logo) }))
    : [{ label: "No usage data yet", enabled: false }];
  template.push({ type: "separator" });
  template.push({ label: "Open dashboard", click: showDashboard });
  template.push({ label: "Refresh", click: () => { void usage(); } });
  template.push({ type: "separator" });
  template.push({ label: "Quit Metria Desktop", click: () => { isQuitting = true; app.quit(); } });
  return Menu.buildFromTemplate(template);
}
function updateTray(providers: typeof lastUsage): void {
  if (!tray) return;
  const rows = usageRows(providers);
  const summary = rows.map((row) => `${row.name} ${row.percent}%`).join(" · ");
  const updated = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date());
  tray.setToolTip(summary ? `${summary} · Updated ${updated}` : `Metria Desktop · Updated ${updated}`);
  if (process.platform === "darwin") tray.setTitle(summary ? ` ${summary}` : "");
  tray.setContextMenu(buildTrayMenu(rows));
}

function createTray(): void {
  const assetIcon = findAsset("metria-logo.png");
  const icon = assetIcon
    ? nativeImage.createFromPath(assetIcon).resize({ width: 18, height: 18 })
    : nativeImage.createFromDataURL("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDE4IDE4Ij48cmVjdCB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHJ4PSI0IiBmaWxsPSIjMDAwIi8+PHBhdGggZD0iTTMgMTNoMlY5SDN6bTQgMGgyVjVIOXptNCAwaDJWN0gxMXptNCAwaDJWM0gxNXoiIGZpbGw9IiNmNGY2ZjgiLz48L3N2Zz4=");
  tray = new Tray(icon);
  updateTray(lastUsage);
}

function validKind(value: unknown): value is ProviderKind { return value === "Claude" || value === "Codex" || value === "OpenCode Go"; }
function trustedWindow(event: Electron.IpcMainInvokeEvent): boolean {
  const url = event.senderFrame?.url;
  if (!url) return false;
  const owners = [window?.webContents, notchWindow?.webContents, cardWindow?.webContents];
  return owners.some((owner) => !!owner && event.sender === owner && url === owner.mainFrame.url);
}
function requireTrustedSender(event: Electron.IpcMainInvokeEvent): void {
  if (!trustedWindow(event)) throw new Error("Untrusted IPC sender.");
}
async function usage() { const current = settings.load(); const values = await providers.fetch(current.enabledProviders); lastUsage = values; publish(values, current.phoneSyncEnabled); updateTray(values); return values; }
function publish(values: Awaited<ReturnType<ProviderService["fetch"]>>, phoneSyncEnabled: boolean): void {
  if (!pairingSecret) { latestSnapshot = Buffer.from("{}", "utf8"); return; }
  const encrypted = encryptedSnapshot(values, pairingSecret);
  latestSnapshot = Buffer.from(encrypted.snapshot);
  if (!shouldPublish(phoneSyncEnabled, pairingSecret)) return;
  void fetch(`https://ntfy.sh/${encrypted.topic}`, { method: "POST", headers: { "Content-Type": "text/plain", Priority: "low" }, body: encrypted.body }).catch(() => undefined);
}
function pairingLink(): string { if (!pairingSecret) throw new Error("Secure storage is unavailable, so phone pairing is disabled."); return `http://127.0.0.1:${(localServer?.address() as { port?: number } | null)?.port ?? 8973}/#s=${pairingSecret.toString("base64url")}&server=https%3A%2F%2Fntfy.sh`; }
function loginItemStatus(): { available: boolean; enabled: boolean; message: string } {
  if (process.platform === "linux") { const path = linuxAutostartPath(); return { available: true, enabled: existsSync(path), message: existsSync(path) ? "Metria Desktop starts through your desktop autostart entry." : "Metria Desktop does not start automatically." }; }
  const enabled = app.getLoginItemSettings().openAtLogin;
  return { available: true, enabled, message: enabled ? "Metria Desktop starts when you sign in." : "Metria Desktop does not start automatically." };
}
function linuxAutostartPath(): string { return join(process.env.XDG_CONFIG_HOME || join(app.getPath("home"), ".config"), "autostart", "metria-desktop.desktop"); }
function setLinuxAutostart(enabled: boolean): void {
  const path = linuxAutostartPath();
  if (!enabled) { try { unlinkSync(path); } catch { /* Not enabled. */ } return; }
  const executable = process.execPath.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
  const content = `[Desktop Entry]\nType=Application\nName=Metria Desktop\nComment=AI coding assistant usage\nExec="${executable}"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n`;
  mkdirSync(join(path, ".."), { recursive: true });
  const temporary = `${path}.tmp`; writeFileSync(temporary, content, { mode: 0o600 }); renameSync(temporary, path);
}

app.setName("Metria Desktop");
app.whenReady().then(() => {
  pairingSecret = pairing.loadOrCreate();
  const pwaRoot = app.isPackaged ? join(process.resourcesPath, "MetriaPWA") : join(app.getAppPath(), "..", "..", "MetriaPWA");
  localServer = startLocalPWA(pwaRoot, () => pairingSecret, () => latestSnapshot);
  createTray(); showDashboard();
  applyDisplayMode();
  ipcMain.handle("metria:get-usage", (event) => { requireTrustedSender(event); return usage(); });
  ipcMain.handle("metria:refresh", (event) => { requireTrustedSender(event); return usage(); });
  ipcMain.handle("metria:get-settings", (event) => { requireTrustedSender(event); return settings.load(); });
  ipcMain.handle("metria:set-provider-enabled", (event, kind: unknown, enabled: unknown) => {
    requireTrustedSender(event); if (!validKind(kind) || typeof enabled !== "boolean") throw new Error("Invalid provider setting."); return settings.setProviderEnabled(kind, enabled);
  });
  ipcMain.handle("metria:reconnect", async (event, kind: unknown) => {
    requireTrustedSender(event); if (!validKind(kind)) throw new Error("Invalid provider.");
    const command = kind === "Claude" ? "claude auth login" : kind === "Codex" ? "codex login" : "opencode auth login";
    await shell.openPath(app.getPath("home"));
    return { command, message: `Run \`${command}\` in your terminal, then refresh Metria.` };
  });
  ipcMain.handle("metria:get-pairing-status", (event) => { requireTrustedSender(event); const secureStorage = pairing.status(); return { enabled: settings.load().phoneSyncEnabled, secureStorage, message: secureStorage === "available" ? "Phone sync is off until you explicitly enable it." : "Secure storage is unavailable. Pairing and phone sync are disabled to protect your secret." }; });
  ipcMain.handle("metria:set-phone-sync-enabled", (event, enabled: unknown) => { requireTrustedSender(event); if (typeof enabled !== "boolean") throw new Error("Invalid phone sync setting."); if (enabled && !pairingSecret) throw new Error("Secure storage is unavailable, so phone sync cannot be enabled."); return settings.setPhoneSyncEnabled(enabled); });
  ipcMain.handle("metria:set-display-mode", (event, mode: unknown) => { requireTrustedSender(event); if (mode !== "tray" && mode !== "notch") throw new Error("Invalid display mode."); const result = settings.setDisplayMode(mode); applyDisplayMode(); return result; });
  ipcMain.handle("metria:set-notch-pinned", (event, pinned: unknown) => { requireTrustedSender(event); if (typeof pinned !== "boolean") throw new Error("Invalid notch setting."); const result = settings.setNotchPinned(pinned); applyDisplayMode(); return result; });
  ipcMain.handle("metria:rail-hover", (event, hovered: unknown) => { if (!isNotchSender(event)) throw new Error("Untrusted IPC sender."); if (typeof hovered !== "boolean") throw new Error("Invalid rail hover state."); railHovered = hovered; updateRail(); });
  ipcMain.handle("metria:provider-hover", (event, providerIndex: unknown) => {
    if (!isNotchSender(event) && !isCardSender(event)) throw new Error("Untrusted IPC sender.");
    if (providerIndex === null) { scheduleCardHide(); return; }
    if (typeof providerIndex !== "number" || !Number.isInteger(providerIndex) || providerIndex < 0) throw new Error("Invalid provider index.");
    const kind = visibleProviders()[providerIndex]?.kind;
    if (kind) showCard(providerIndex, kind);
  });
  ipcMain.handle("metria:card-resize", (event, height: unknown) => {
    if (!isCardSender(event) || cardActiveIndex === null) throw new Error("Untrusted IPC sender.");
    if (typeof height !== "number" || !Number.isFinite(height)) throw new Error("Invalid card height.");
    cardWindow?.setBounds(cardBounds(notchArea(), cardActiveIndex, Math.max(NOTCH.hiddenHeight, Math.round(height))));
  });
  ipcMain.handle("metria:open-dashboard", (event) => { if (!isNotchSender(event)) throw new Error("Untrusted IPC sender."); showDashboard(); });
  ipcMain.handle("metria:get-pairing-link", (event) => { requireTrustedSender(event); return pairingLink(); });
  ipcMain.handle("metria:get-pairing-qr", async (event) => { requireTrustedSender(event); return QRCode.toDataURL(pairingLink(), { errorCorrectionLevel: "M", margin: 1, width: 240 }); });
  ipcMain.handle("metria:get-login-item-status", (event) => { requireTrustedSender(event); return loginItemStatus(); });
  ipcMain.handle("metria:set-launch-at-login", (event, enabled: unknown) => {
    requireTrustedSender(event);
    if (typeof enabled !== "boolean") throw new Error("Invalid launch-at-login setting.");
    if (process.platform === "linux") setLinuxAutostart(enabled);
    else app.setLoginItemSettings({ openAtLogin: enabled });
    return loginItemStatus();
  });
  ipcMain.handle("metria:regenerate-pairing", (event) => { requireTrustedSender(event); pairingSecret = pairing.rotate(); return pairingLink(); });
  refreshTimer = setInterval(() => { void usage(); }, settings.load().refreshIntervalSeconds * 1000);
});
app.on("window-all-closed", () => { /* Metria remains available through the tray. */ });
app.on("before-quit", () => { isQuitting = true; if (refreshTimer) clearInterval(refreshTimer); clearTimeout(pendingCardHide); localServer?.close(); });
