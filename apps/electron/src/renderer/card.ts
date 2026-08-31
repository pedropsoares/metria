import type { AppSettings, CardShowPayload, ProviderKind, ProviderUsage, UsageWindow } from "../shared/types";

const title = document.getElementById("card-title")!;
const content = document.getElementById("card-content")!;
const body = document.body;

let current: { index: number; kind: ProviderKind } | null = null;
let settings: AppSettings = { enabledProviders: [], refreshIntervalSeconds: 300, phoneSyncEnabled: false, displayMode: "tray", notchPinned: true };

const KIND: Record<ProviderKind, { label: string; logo: string }> = {
  "Claude": { label: "Claude", logo: "claude-logo.png" },
  "Codex": { label: "Codex", logo: "codex-logo.png" },
  "OpenCode Go": { label: "Go", logo: "opencode-logo.png" }
};

function gaugeColor(percent: number): string {
  if (percent >= 85) return "#ff453a";
  if (percent >= 65) return "#ff9f0a";
  if (percent >= 40) return "#ffd60a";
  return "#30d158";
}

function logo(kind: ProviderKind): string {
  return `<img class="provider-logo" src="./${KIND[kind].logo}" alt="">`;
}

function resetText(resetDate: string | null): string {
  if (!resetDate) return "No reset data";
  const seconds = (new Date(resetDate).getTime() - Date.now()) / 1000;
  if (seconds > 0 && seconds < 86400) {
    const totalMinutes = Math.floor(seconds / 60);
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;
    if (hours > 0) return minutes > 0 ? `Resets in ${hours} hr ${minutes} min` : `Resets in ${hours} hr`;
    return `Resets in ${minutes} min`;
  }
  return `Resets ${new Date(resetDate).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}`;
}

function windowRow(windowUsage: UsageWindow): HTMLElement {
  const row = document.createElement("div");
  row.className = "card-window";
  const percent = Math.max(0, Math.min(100, windowUsage.percent));
  const head = document.createElement("div");
  head.className = "card-row";
  const name = document.createElement("span");
  name.textContent = windowUsage.title;
  const reset = document.createElement("span");
  reset.className = "card-reset";
  reset.textContent = resetText(windowUsage.resetDate);
  head.append(name, reset);

  const track = document.createElement("div");
  track.className = "card-track";
  const fill = document.createElement("i");
  fill.className = "gauge-fill";
  fill.style.background = gaugeColor(percent);
  fill.style.width = `${percent}%`;
  track.appendChild(fill);

  const pct = document.createElement("div");
  pct.className = "card-pct";
  pct.textContent = `${Math.round(percent)}% Used`;

  row.append(head, track, pct);
  return row;
}

function render(provider: ProviderUsage): void {
  const kind = KIND[provider.kind] ?? KIND["Claude"];
  title.replaceChildren();
  const logoMark = document.createElement("span");
  logoMark.innerHTML = logo(provider.kind);
  const label = document.createElement("span");
  label.textContent = kind.label;
  const dot = document.createElement("span");
  dot.className = "dot";
  dot.style.background = provider.error ? "#ff9f0a" : "#30d158";
  title.append(logoMark, label, dot);
  content.replaceChildren();
  if (provider.windows.length === 0) {
    const empty = document.createElement("div");
    empty.className = "card-empty";
    empty.textContent = provider.error ?? "Waiting for usage data...";
    content.appendChild(empty);
    if (provider.error) {
      const error = document.createElement("p");
      error.className = "card-error";
      error.textContent = provider.error;
      content.appendChild(error);
    }
  } else {
    provider.windows.forEach((windowUsage) => content.appendChild(windowRow(windowUsage)));
  }
  requestAnimationFrame(() => {
    const height = Math.ceil(body.scrollHeight);
    void window.metria.resizeCard(height);
  });
}

async function show(payload: CardShowPayload): Promise<void> {
  current = payload;
  settings = await window.metria.getSettings();
  const all = await window.metria.getUsage();
  const provider = all.find((candidate) => candidate.kind === payload.kind);
  if (provider) render(provider);
}

window.metria.onCardHide(() => { current = null; });
window.metria.onCardShow((payload) => { void show(payload); });
body.addEventListener("mouseenter", () => { if (current) void window.metria.setProviderHover(current.index); });
body.addEventListener("mouseleave", () => { void window.metria.setProviderHover(null); });

void (async () => { settings = await window.metria.getSettings(); })();
