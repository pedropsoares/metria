import type { ProviderKind, ProviderUsage } from "../shared/types";

const providerRoot = document.querySelector<HTMLDivElement>("#providers")!;
const status = document.querySelector<HTMLParagraphElement>("#status")!;
const refresh = document.querySelector<HTMLButtonElement>("#refresh")!;
const pairingLink = document.querySelector<HTMLParagraphElement>("#pairing-link")!;
const regenerate = document.querySelector<HTMLButtonElement>("#regenerate")!;
const phoneSync = document.querySelector<HTMLInputElement>("#phone-sync")!;
const pairingStatus = document.querySelector<HTMLParagraphElement>("#pairing-status")!;
const pairingQR = document.querySelector<HTMLImageElement>("#pairing-qr")!;
const notchMode = document.querySelector<HTMLInputElement>("#notch-mode")!;

const kindClass: Record<ProviderKind, string> = { Claude: "claude", Codex: "codex", "OpenCode Go": "go" };
function percentage(value: number): string { return `${Math.max(0, Math.min(100, value)).toFixed(0)}%`; }
function date(value: string | null): string { return value ? `Resets ${new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))}` : "No reset time available"; }

function gaugeColor(percent: number): string { return percent >= 85 ? "#ff453a" : percent >= 65 ? "#ff9f0a" : percent >= 40 ? "#ffd60a" : "#30d158"; }
const logoFile: Record<ProviderKind, string> = { Claude: "claude-logo.png", Codex: "codex-logo.png", "OpenCode Go": "opencode-logo.png" };

function card(provider: ProviderUsage): HTMLElement {
  const article = document.createElement("article"); article.className = `provider ${kindClass[provider.kind]}`;
  const title = document.createElement("div"); title.className = "provider-title";
  const head = document.createElement("div"); head.className = "provider-h";
  const logo = document.createElement("img"); logo.className = "provider-logo"; logo.src = `./${logoFile[provider.kind]}`;
  const dot = document.createElement("span"); dot.className = "status-dot"; dot.style.background = provider.error ? "#ff9f0a" : "#30d158";
  const name = document.createElement("h2"); name.textContent = provider.kind;
  head.append(logo, name, dot);
  const toggle = document.createElement("button"); toggle.type = "button"; toggle.textContent = provider.available ? "Disable" : "Setup";
  toggle.addEventListener("click", async () => { if (provider.available) await window.metria.setProviderEnabled(provider.kind, false); else status.textContent = (await window.metria.reconnect(provider.kind)).message; await load(); });
  title.append(head, toggle); article.append(title);
  if (!provider.available) { const hint = document.createElement("p"); hint.className = "hint"; hint.textContent = provider.setupHint; article.append(hint); return article; }
  if (provider.error) { const error = document.createElement("p"); error.className = "hint"; error.textContent = provider.error; article.append(error); }
  for (const windowUsage of provider.windows) { const row = document.createElement("div"); row.className = "usage"; const headRow = document.createElement("div"); const label = document.createElement("span"); label.textContent = windowUsage.title; const value = document.createElement("strong"); value.textContent = percentage(windowUsage.percent); headRow.append(label, value); const track = document.createElement("div"); track.className = "track"; const fill = document.createElement("i"); fill.style.width = percentage(windowUsage.percent); fill.style.background = gaugeColor(windowUsage.percent); track.appendChild(fill); const foot = document.createElement("small"); foot.textContent = date(windowUsage.resetDate); row.append(headRow, track, foot); article.append(row); }
  return article;
}
async function load(): Promise<void> { refresh.disabled = true; status.textContent = "Refreshing usage…"; try { const items = await window.metria.refresh(); providerRoot.replaceChildren(...items.map(card)); status.textContent = `Updated ${new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(new Date())}`; } catch { status.textContent = "Metria could not refresh usage."; } finally { refresh.disabled = false; } }
refresh.addEventListener("click", () => { void load(); });
async function loadPairing(): Promise<void> {
  const pairing = await window.metria.getPairingStatus();
  phoneSync.checked = pairing.enabled;
  phoneSync.disabled = pairing.secureStorage !== "available";
  pairingStatus.textContent = pairing.message;
  pairingLink.hidden = !pairing.enabled || pairing.secureStorage !== "available";
  pairingQR.hidden = pairingLink.hidden;
  regenerate.hidden = pairingLink.hidden;
  if (!pairingLink.hidden) { pairingLink.textContent = await window.metria.getPairingLink(); pairingQR.src = await window.metria.getPairingQRCode(); }
  const settings = await window.metria.getSettings();
  notchMode.checked = settings.displayMode === "notch";
}
notchMode.addEventListener("change", () => { void window.metria.setDisplayMode(notchMode.checked ? "notch" : "tray"); });
phoneSync.addEventListener("change", () => { void window.metria.setPhoneSyncEnabled(phoneSync.checked).then(loadPairing).catch((error: Error) => { status.textContent = error.message; void loadPairing(); }); });
regenerate.addEventListener("click", () => { void window.metria.regeneratePairing().then((link) => { pairingLink.textContent = link; }).catch((error: Error) => { status.textContent = error.message; }); });
void loadPairing();
void load();
