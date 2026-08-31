import type { AppSettings, ProviderKind, ProviderUsage } from "../shared/types";

const rail = document.getElementById("rail")!;
const providersEl = document.getElementById("providers")!;
const gear = document.getElementById("gear")!;
const eye = document.getElementById("eye")!;
const body = document.body;

let settings: AppSettings = { enabledProviders: [], refreshIntervalSeconds: 300, phoneSyncEnabled: false, displayMode: "tray", notchPinned: true };
let usage: ProviderUsage[] = [];
let railHovered = false;
let collapsed = false;

const KIND: Record<ProviderKind, { logo: string; color: string; gradient: string }> = {
  "Claude": { logo: "claude-logo.png", color: "#ff9f0a", gradient: "none" },
  "Codex": { logo: "codex-logo.png", color: "#0a84ff", gradient: "url(#codex-ring)" },
  "OpenCode Go": { logo: "opencode-logo.png", color: "#ffffff", gradient: "none" }
};

function percentage(value: number): number { return Math.max(0, Math.min(100, value)); }
function primary(provider: ProviderUsage): number { return provider.windows[0]?.percent ?? 0; }

function ring(provider: ProviderUsage): string {
  const clamped = percentage(primary(provider));
  const r = 17;
  const c = 2 * Math.PI * r;
  const kind = KIND[provider.kind];
  const stroke = provider.kind === "Codex" ? kind.gradient : kind.color;
  const gradientDef = provider.kind === "Codex" ? `<defs><linearGradient id="codex-ring" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0a84ff"/><stop offset="1" stop-color="#bf5af2"/></linearGradient></defs>` : "";
  const dashOffset = (c * (1 - clamped / 100)).toFixed(2);
  return `<span class="ring-wrap"><svg class="ring" width="38" height="38" viewBox="0 0 38 38">${gradientDef}<circle cx="19" cy="19" r="${r}" fill="none" stroke="#2c2c2c" stroke-width="5"/><circle cx="19" cy="19" r="${r}" fill="none" stroke="${stroke}" stroke-width="2" stroke-linecap="round" stroke-dasharray="${c.toFixed(2)} ${c.toFixed(2)}" stroke-dashoffset="${dashOffset}" transform="rotate(-90 19 19)"/></svg><img class="ring-logo" src="./${kind.logo}" alt=""></span>`;
}

function item(provider: ProviderUsage, index: number): HTMLElement {
  const el = document.createElement("div");
  el.className = "provider-item";
  el.innerHTML = ring(provider) + `<span class="pct">${Math.round(percentage(primary(provider)))}%</span>`;
  el.addEventListener("mouseenter", () => { void window.metria.setProviderHover(index); });
  el.addEventListener("mouseleave", () => { void window.metria.setProviderHover(null); });
  return el;
}

function visible(): ProviderUsage[] {
  return usage.filter((provider) => settings.enabledProviders.includes(provider.kind) && provider.available);
}

function render(): void {
  providersEl.replaceChildren(...visible().map((provider, index) => item(provider, index)));
}

function applyState(): void {
  body.classList.toggle("rail-hovered", railHovered);
  body.classList.toggle("rail-collapsed", collapsed);
}

function update(): void {
  railHovered = false;
  applyState();
}

rail.addEventListener("mouseenter", () => { railHovered = true; applyState(); void window.metria.setRailHovered(true); });
rail.addEventListener("mouseleave", () => { railHovered = false; applyState(); void window.metria.setRailHovered(false); });
gear.addEventListener("click", () => { void window.metria.openDashboard(); });
eye.addEventListener("click", async () => { await window.metria.setNotchPinned(!settings.notchPinned); settings = await window.metria.getSettings(); });

window.metria.onRailState((state) => { collapsed = state.collapsed; applyState(); });

async function load(): Promise<void> {
  [settings, usage] = await Promise.all([window.metria.getSettings(), window.metria.getUsage()]);
  render();
}

void load();
setInterval(() => { void load(); }, settings.refreshIntervalSeconds * 1000);
void update();
