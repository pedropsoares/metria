import { app, BrowserWindow, ipcMain, Menu, nativeImage, screen, shell, Tray } from "electron";
import { autoUpdater } from "electron-updater";
import { dirname, join } from "node:path";
import { existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { ProviderService } from "./providers";
import { SettingsStore } from "./settings";
import type { ProviderKind, ProviderSourceChoice, ProviderUsage } from "../shared/types";

let window: BrowserWindow | undefined;
let widgetWindow: BrowserWindow | undefined;
let cardWindow: BrowserWindow | undefined;
let cardActiveIndex: number | null = null;
let pendingCardHide: NodeJS.Timeout | undefined;
let tray: Tray | undefined;
let refreshTimer: NodeJS.Timeout | undefined;
let isQuitting = false;
let lastUsage: Awaited<ReturnType<ProviderService["fetch"]>> = [];
let badgeTrays = new Map<ProviderKind, Tray>();
let updateState: "idle" | "downloaded" = "idle";
let updateTimer: NodeJS.Timeout | undefined;
const settings = new SettingsStore();
const providers = new ProviderService(() => settings.load());

function createWindow(): BrowserWindow {
  const next = new BrowserWindow({
    width: 760, height: 680, minWidth: 480, minHeight: 560, show: false,
    title: "Metria Electron",
    icon: findAsset("metria-mascot.png"),
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
  next.on("minimize", () => next.hide());
  return next;
}

function showDashboard(): void { if (!window) window = createWindow(); window.show(); window.focus(); }

/** Opaque compact widget that is always visible on Linux, where the system
 * tray (StatusNotifierItem) is unavailable to GUI apps, including WSLg. */
const WIDGET_WIDTH = 88;
const WIDGET_ITEM_HEIGHT = 52;
const WIDGET_ITEM_GAP = 8;
const WIDGET_PADDING = 12;
function displayArea(): Electron.Rectangle {
  return screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
}
function widgetBounds(area: Electron.Rectangle, providerCount: number): Electron.Rectangle {
  const height = Math.max(76, providerCount * WIDGET_ITEM_HEIGHT + (Math.max(0, providerCount - 1) * WIDGET_ITEM_GAP) + WIDGET_PADDING * 2);
  const offset = settings.load().widgetYOffset;
  const y = Math.min(Math.max(area.y + offset, area.y), Math.max(area.y, area.y + area.height - height));
  return { x: area.x + area.width - WIDGET_WIDTH - 12, y, width: WIDGET_WIDTH, height };
}
function createWidgetWindow(): BrowserWindow {
  const widget = new BrowserWindow({
    width: WIDGET_WIDTH, height: 120, frame: false, resizable: false, movable: false,
    backgroundColor: "#0d1117", skipTaskbar: true, alwaysOnTop: true, hasShadow: false, type: "toolbar", title: "Metria usage widget",
    webPreferences: { preload: join(__dirname, "../preload/index.js"), contextIsolation: true, sandbox: true, nodeIntegration: false }
  });
  widget.loadFile(join(__dirname, "../renderer/widget.html"));
  // Same re-assert on mapping as the card: compositors may override pre-show bounds.
  widget.on("show", () => { widget.setAlwaysOnTop(true); updateWidgetBounds(lastUsage); });
  widget.on("closed", () => { widgetWindow = undefined; hideCard(); });
  widget.setAlwaysOnTop(true);
  return widget;
}
function updateWidgetBounds(values: typeof lastUsage): void {
  if (!widgetWindow) return;
  const enabled = settings.load().enabledProviders;
  const count = values.filter((provider) => enabled.includes(provider.kind) && provider.available).length;
  widgetWindow.setBounds(widgetBounds(displayArea(), count));
  if (cardActiveIndex !== null) positionCard(cardActiveIndex);
}

/** Hover card shown to the left of the widget while pointing at a provider. */
const CARD_WIDTH = 316;
const CARD_SPACING = 12;
const CARD_MAX_HEIGHT = 520;

function visibleProviders(): typeof lastUsage {
  const enabled = settings.load().enabledProviders;
  return lastUsage.filter((provider) => enabled.includes(provider.kind) && provider.available);
}

function createCardWindow(): BrowserWindow {
  const initial = cardBounds(cardActiveIndex ?? 0);
  const card = new BrowserWindow({
    x: initial.x, y: initial.y, width: initial.width, height: initial.height,
    frame: false, transparent: true, resizable: false, movable: false,
    skipTaskbar: true, alwaysOnTop: true, hasShadow: false, type: "toolbar", show: false, title: "Metria usage card",
    webPreferences: { preload: join(__dirname, "../preload/index.js"), contextIsolation: true, sandbox: true, nodeIntegration: false }
  });
  card.loadFile(join(__dirname, "../renderer/card.html"));
  // The card may be shown again before it finishes loading; deliver the payload on load.
  card.webContents.on("did-finish-load", () => refreshCard());
  // Frameless/transparent windows can be centered by some Linux compositors
  // when first mapped, overriding the pre-show bounds; re-assert after mapping.
  card.on("show", () => { if (cardActiveIndex !== null) positionCard(cardActiveIndex); });
  card.on("closed", () => { cardWindow = undefined; });
  return card;
}

function showCard(index: number): void {
  clearTimeout(pendingCardHide);
  const provider = visibleProviders()[index];
  if (!provider) return;
  // Already visible: keep-alive signals must not re-show, but the card may be
  // stale if the widget moved under the cursor (e.g. after a drag), so re-assert.
  if (cardWindow?.isVisible() && cardActiveIndex === index) { positionCard(index); return; }
  const changed = cardActiveIndex !== index || !cardWindow;
  cardActiveIndex = index;
  if (!cardWindow) cardWindow = createCardWindow();
  if (changed) cardWindow.webContents.send("metria:card-show", { index, kind: provider.kind });
  positionCard(index);
  cardWindow.showInactive();
}

function hideCard(): void {
  cardActiveIndex = null;
  cardWindow?.webContents.send("metria:card-hide");
  cardWindow?.hide();
}

function scheduleCardHide(): void {
  clearTimeout(pendingCardHide);
  pendingCardHide = setTimeout(hideCard, 200);
}

function refreshCard(): void {
  if (cardActiveIndex === null || !cardWindow) return;
  const provider = visibleProviders()[cardActiveIndex];
  if (!provider) { hideCard(); return; }
  cardWindow.webContents.send("metria:card-show", { index: cardActiveIndex, kind: provider.kind });
  positionCard(cardActiveIndex);
}

/** Card sits to the left of the widget, vertically centred on the hovered item.
 * If the widget is gone, anchor to the display's right edge so the card never
 * falls back to the centered default position of a fresh BrowserWindow. */
function cardBounds(index: number, height?: number): Electron.Rectangle {
  const area = widgetWindow?.getBounds();
  const workArea = displayArea();
  const cardHeight = Math.min(height ?? 200, CARD_MAX_HEIGHT);
  const anchorTop = (area ?? workArea).y;
  const itemCenterY = anchorTop + WIDGET_PADDING + index * (WIDGET_ITEM_HEIGHT + WIDGET_ITEM_GAP) + WIDGET_ITEM_HEIGHT / 2;
  // Vertically center the card on the hovered item.
  const minY = workArea.y + 8;
  const maxY = workArea.y + workArea.height - cardHeight - 8;
  const y = Math.min(Math.max(itemCenterY - cardHeight / 2, minY), Math.max(minY, maxY));
  const anchorX = area ? area.x : workArea.x + workArea.width;
  const x = anchorX - CARD_SPACING - CARD_WIDTH;
  return { x, y, width: CARD_WIDTH, height: cardHeight };
}

function positionCard(index: number, height?: number): void {
  if (!cardWindow) return;
  cardWindow.setBounds(cardBounds(index, height ?? cardWindow.getBounds().height), false);
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
    : [join(app.getAppPath(), "..", "..", "Assets", name), join(app.getAppPath(), "..", "pwa", "public", name)];
  return candidates.find((candidate) => existsSync(candidate));
}
const FALLBACK_ICON = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDE4IDE4Ij48cmVjdCB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHJ4PSI0IiBmaWxsPSIjMDAwIi8+PHBhdGggZD0iTTMgMTNoMlY5SDN6bTQgMGgyVjVIOXptNCAwaDJWN0gxMXptNCAwaDJWM0gxNXoiIGZpbGw9IiNmNGY2ZjgiLz48L3N2Zz4=";
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
  if (updateState === "downloaded") template.push({ label: "Restart & install update", click: () => { autoUpdater.quitAndInstall(); } });
  template.push({ label: "Check for updates…", click: () => { void autoUpdater.checkForUpdates().catch(() => undefined); } });
  template.push({ type: "separator" });
  template.push({ label: "Quit Metria Electron", click: () => { isQuitting = true; app.quit(); } });
  return Menu.buildFromTemplate(template);
}

/** Silent auto-update mirroring the native Sparkle flow: download in the
 * background and install on quit, exposed through the tray menu only. macOS
 * stays out because electron-updater needs a signed app there. */
function initAutoUpdater(): void {
  if (!app.isPackaged) return;
  autoUpdater.autoDownload = true;
  autoUpdater.on("update-downloaded", () => { updateState = "downloaded"; updateTray(lastUsage); });
  autoUpdater.on("error", (error) => { console.error("Metria auto-update failed:", error.message); });
  const check = (): void => { void autoUpdater.checkForUpdates().catch(() => undefined); };
  setTimeout(check, 20_000);
  updateTimer = setInterval(check, 6 * 60 * 60 * 1000);
}
function restartRefreshTimer(): void {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => { void usage(); }, settings.load().refreshIntervalSeconds * 1000);
}
function updateTray(providers: typeof lastUsage): void {
  if (!tray) return;
  const rows = usageRows(providers);
  const summary = rows.map((row) => `${row.name} ${row.percent}%`).join(" · ");
  const updated = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date());
  tray.setToolTip(summary ? `${summary} · Updated ${updated}` : `Metria Electron · Updated ${updated}`);
  tray.setContextMenu(buildTrayMenu(rows));
}

function createTray(): void {
  const assetIcon = findAsset("metria-mascot.png");
  const icon = assetIcon
    ? nativeImage.createFromPath(assetIcon).resize({ width: 18, height: 18 })
    : nativeImage.createFromDataURL(FALLBACK_ICON);
  tray = new Tray(icon);
  updateTray(lastUsage);
}

/**
 * Each enabled and available provider gets its own tray badge sitting next to
 * the Metria tray icon. The badge shows the provider logo and reports the
 * primary window percentage in its tooltip, then opens the dashboard on click.
 */
function badgeStatus(provider: ProviderUsage): { percent: number; reset: string } {
  const first = provider.windows[0];
  return { percent: Math.round(Math.max(0, Math.min(100, first?.percent ?? 0))), reset: formatReset(first?.resetDate ?? null) };
}
function badgeTemplate(): Electron.MenuItemConstructorOptions[] {
  return [
    { label: "Open dashboard", click: showDashboard },
    { label: "Refresh", click: () => { void usage(); } }
  ];
}
function updateBadges(providers: typeof lastUsage): void {
  const enabled = settings.load().enabledProviders;
  const active = providers.filter((provider) => enabled.includes(provider.kind) && provider.available);
  for (const [kind, badge] of badgeTrays) {
    if (!active.some((provider) => provider.kind === kind)) { badge.destroy(); badgeTrays.delete(kind); }
  }
  for (const provider of active) {
    const { percent, reset } = badgeStatus(provider);
    const tooltip = `${providerLabel(provider.kind)} — ${percent}%${reset ? ` · ${reset}` : ""}`;
    const existing = badgeTrays.get(provider.kind);
    if (existing) {
      existing.setToolTip(tooltip);
      continue;
    }
    const icon = trayMenuIcon(TRAY_LOGOS[provider.kind]) ?? nativeImage.createFromDataURL(FALLBACK_ICON);
    const badge = new Tray(icon);
    badge.setToolTip(tooltip);
    badge.setContextMenu(Menu.buildFromTemplate(badgeTemplate()));
    badge.on("click", showDashboard);
    badgeTrays.set(provider.kind, badge);
  }
}

function validKind(value: unknown): value is ProviderKind { return value === "Claude" || value === "Codex" || value === "OpenCode Go"; }
function validProviderSource(value: unknown): value is ProviderSourceChoice {
  if (typeof value !== "object" || value === null) return false;
  const source = value as Record<string, unknown>;
  if (source.location === "host") return true;
  return source.location === "wsl" && typeof source.distro === "string" && source.distro.length > 0;
}
function trustedWindow(event: Electron.IpcMainInvokeEvent): boolean {
  const url = event.senderFrame?.url;
  if (!url) return false;
  const owners = [window?.webContents, widgetWindow?.webContents, cardWindow?.webContents];
  return owners.some((owner) => !!owner && event.sender === owner && url === owner.mainFrame.url);
}
function requireTrustedSender(event: Electron.IpcMainInvokeEvent): void {
  if (!trustedWindow(event)) throw new Error("Untrusted IPC sender.");
}
// The dashboard must show every provider (enabled or not) so users can re-enable
// from there; taps, badges, and the widget keep filtering by enabledProviders.
const ALL_KINDS: ProviderKind[] = ["Claude", "Codex", "OpenCode Go"];
async function usage() { const values = await providers.fetch(ALL_KINDS); lastUsage = values; updateTray(values); if (process.platform === "linux") { updateWidgetBounds(values); refreshCard(); } else updateBadges(values); return values; }
function loginItemStatus(): { available: boolean; enabled: boolean; message: string } {
  if (process.platform === "linux") { const path = linuxAutostartPath(); return { available: true, enabled: existsSync(path), message: existsSync(path) ? "Metria Electron starts through your desktop autostart entry." : "Metria Electron does not start automatically." }; }
  const enabled = app.getLoginItemSettings().openAtLogin;
  return { available: true, enabled, message: enabled ? "Metria Electron starts when you sign in." : "Metria Electron does not start automatically." };
}
function linuxAutostartPath(): string { return join(process.env.XDG_CONFIG_HOME || join(app.getPath("home"), ".config"), "autostart", "metria-electron.desktop"); }
function setLinuxAutostart(enabled: boolean): void {
  const path = linuxAutostartPath();
  const legacyPath = join(process.env.XDG_CONFIG_HOME || join(app.getPath("home"), ".config"), "autostart", "metria-desktop.desktop");
  if (!enabled) { try { unlinkSync(path); } catch { /* Not enabled. */ } return; }
  try { if (legacyPath !== path) unlinkSync(legacyPath); } catch { /* No legacy entry. */ }
  const executable = process.execPath.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
  const content = `[Desktop Entry]\nType=Application\nName=Metria Electron\nComment=AI coding assistant usage\nExec="${executable}"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n`;
  mkdirSync(join(path, ".."), { recursive: true });
  const temporary = `${path}.tmp`; writeFileSync(temporary, content, { mode: 0o600 }); renameSync(temporary, path);
}

app.setName("Metria Electron");
if (process.platform === "linux") {
  // Reduced-compositing environments (no DRI3/VA-API render node) crash the GPU
  // process and can fail to draw windows. Software compositing on Linux avoids
  // the crash; keep hardware acceleration on macOS.
  app.disableHardwareAcceleration();
}
app.whenReady().then(() => {
  createTray(); showDashboard(); initAutoUpdater();
  if (process.platform === "linux") {
    widgetWindow = createWidgetWindow();
    widgetWindow.setBounds(widgetBounds(displayArea(), 0));
    widgetWindow.showInactive();
  }
  ipcMain.handle("metria:get-usage", (event) => { requireTrustedSender(event); return usage(); });
  ipcMain.handle("metria:open-dashboard", (event) => { requireTrustedSender(event); showDashboard(); });
  ipcMain.handle("metria:provider-hover", (event, index: unknown) => {
    requireTrustedSender(event);
    if (index === null) { scheduleCardHide(); return; }
    if (typeof index !== "number" || !Number.isInteger(index) || index < 0 || index >= visibleProviders().length) throw new Error("Invalid provider index.");
    showCard(index);
  });
  ipcMain.handle("metria:card-resize", (event, height: unknown) => {
    requireTrustedSender(event);
    if (typeof height !== "number" || !Number.isFinite(height)) throw new Error("Invalid card height.");
    if (cardActiveIndex !== null) positionCard(cardActiveIndex, height);
  });
  ipcMain.handle("metria:refresh", (event) => { requireTrustedSender(event); return usage(); });
  ipcMain.handle("metria:get-settings", (event) => { requireTrustedSender(event); return settings.load(); });
  ipcMain.handle("metria:set-provider-enabled", (event, kind: unknown, enabled: unknown) => {
    requireTrustedSender(event); if (!validKind(kind) || typeof enabled !== "boolean") throw new Error("Invalid provider setting.");
    const next = settings.setProviderEnabled(kind, enabled);
    // The widget (notch) keeps its own settings snapshot; refresh it and the bounds now.
    updateWidgetBounds(lastUsage);
    widgetWindow?.webContents.send("metria:settings-changed");
    return next;
  });
  ipcMain.handle("metria:reconnect", async (event, kind: unknown) => {
    requireTrustedSender(event); if (!validKind(kind)) throw new Error("Invalid provider.");
    const command = kind === "Claude" ? "claude auth login" : kind === "Codex" ? "codex login" : "opencode auth login";
    await shell.openPath(app.getPath("home"));
    return { command, message: `Run \`${command}\` in your terminal, then refresh Metria.` };
  });
  ipcMain.handle("metria:set-widget-y-offset", (event, offsetY: unknown) => {
    requireTrustedSender(event);
    if (typeof offsetY !== "number" || !Number.isFinite(offsetY)) throw new Error("Invalid widget offset.");
    // Persist the clamped value (like the native app derives its stored offset
    // from the clamped frame), so drags always restart from a valid position
    // and never accumulate an offset outside the work area.
    const area = displayArea();
    const height = widgetWindow?.getBounds().height ?? 120;
    const clamped = Math.max(0, Math.min(Math.round(offsetY), Math.max(0, area.height - height)));
    const next = settings.setWidgetYOffset(clamped);
    updateWidgetBounds(lastUsage); refreshCard();
    return next;
  });
  ipcMain.handle("metria:get-login-item-status", (event) => { requireTrustedSender(event); return loginItemStatus(); });
  ipcMain.handle("metria:app-info", (event) => {
    requireTrustedSender(event);
    return { version: app.getVersion(), platform: process.platform, packaged: app.isPackaged, dataPath: app.getPath("userData") };
  });
  ipcMain.handle("metria:check-updates", async (event) => {
    requireTrustedSender(event);
    if (!app.isPackaged) return { status: "unavailable", message: "Automatic updates are only available in packaged builds." };
    try {
      await autoUpdater.checkForUpdates();
      if (updateState === "downloaded") return { status: "downloaded", message: "An update was downloaded and will install on quit." };
      return { status: "up-to-date", message: "Metria Electron is up to date." };
    } catch (error) {
      return { status: "error", message: `Update check failed: ${error instanceof Error ? error.message : String(error)}` };
    }
  });
  ipcMain.handle("metria:install-update", (event) => {
    requireTrustedSender(event);
    if (updateState !== "downloaded") throw new Error("No downloaded update.");
    isQuitting = true;
    autoUpdater.quitAndInstall();
  });
  ipcMain.handle("metria:uninstall", (event) => {
    requireTrustedSender(event);
    if (process.platform === "win32") {
      const uninstaller = join(dirname(process.execPath), "Uninstall Metria Electron.exe");
      if (!existsSync(uninstaller)) return { opened: false, message: "The uninstaller was not found next to the app. You can uninstall Metria Electron from the Windows Settings app." };
      void shell.openPath(uninstaller);
      return { opened: true, message: "The uninstaller is starting." };
    }
    if (process.platform === "linux") {
      shell.showItemInFolder(process.execPath);
      return { opened: true, message: "To uninstall, delete the Metria Electron file and its autostart entry." };
    }
    return { opened: false, message: "Uninstall is only available on Windows and Linux." };
  });
  ipcMain.handle("metria:quit", (event) => { requireTrustedSender(event); isQuitting = true; app.quit(); });
  ipcMain.handle("metria:set-launch-at-login", (event, enabled: unknown) => {
    requireTrustedSender(event);
    if (typeof enabled !== "boolean") throw new Error("Invalid launch-at-login setting.");
    if (process.platform === "linux") setLinuxAutostart(enabled);
    else app.setLoginItemSettings({ openAtLogin: enabled });
    return loginItemStatus();
  });
  ipcMain.handle("metria:set-refresh-interval", (event, seconds: unknown) => {
    requireTrustedSender(event);
    if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 60) throw new Error("Invalid refresh interval.");
    const next = settings.setRefreshInterval(seconds);
    restartRefreshTimer();
    return next;
  });
  ipcMain.handle("metria:get-provider-sources", (event) => {
    requireTrustedSender(event);
    return providers.sources(ALL_KINDS);
  });
  ipcMain.handle("metria:set-provider-source", (event, kind: unknown, source: unknown) => {
    requireTrustedSender(event);
    if (!validKind(kind) || !validProviderSource(source)) throw new Error("Invalid provider source.");
    const next = settings.setProviderSource(kind, source);
    updateWidgetBounds(lastUsage);
    widgetWindow?.webContents.send("metria:settings-changed");
    void usage();
    return next;
  });
  restartRefreshTimer();
});
app.on("window-all-closed", () => { /* Metria remains available through the tray. */ });
app.on("before-quit", () => { isQuitting = true; if (refreshTimer) clearInterval(refreshTimer); if (updateTimer) clearInterval(updateTimer); });
