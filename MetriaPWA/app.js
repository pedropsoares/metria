const CONFIG_KEY = "metriaPwaConfig";
const SNAPSHOT_KEY = "metriaPwaSnapshot";
let eventSource;

const setup = document.querySelector("#setup");
const dashboard = document.querySelector("#dashboard");
const form = document.querySelector("#topicForm");
const serverInput = document.querySelector("#serverInput");
const topicInput = document.querySelector("#topicInput");
const status = document.querySelector("#connectionStatus");
const providerGrid = document.querySelector("#providerGrid");
const emptyState = document.querySelector("#emptyState");
const lastUpdated = document.querySelector("#lastUpdated");

function setStatus(label, state) {
  status.textContent = label;
  status.className = `status status-${state}`;
}

function normalizeServer(server) {
  return server.replace(/\/+$/, "");
}

function renderSnapshot(snapshot) {
  const providers = Array.isArray(snapshot?.providers) ? snapshot.providers : [];
  providerGrid.innerHTML = providers.map((provider) => {
    const percent = Math.max(0, Math.min(100, Number(provider.percent) || 0));
    return `<article class="provider-card">
      <div class="card-topline"><span>${escapeHtml(provider.name)}</span><strong>${Math.round(percent)}%</strong></div>
      <div class="progress-track"><div class="progress-bar" style="width: ${percent}%"></div></div>
      <p>${provider.resetDate ? `Resets ${formatDate(provider.resetDate)}` : "No reset date"}</p>
    </article>`;
  }).join("");
  emptyState.hidden = providers.length > 0;
  if (snapshot?.updatedAt) {
    lastUpdated.textContent = `Updated ${formatDate(snapshot.updatedAt)}`;
  }
}

function formatDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "recently" : date.toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
}

function connect(config) {
  eventSource?.close();
  setup.hidden = true;
  dashboard.hidden = false;
  setStatus("Connecting", "connecting");
  const streamUrl = `${normalizeServer(config.server)}/${encodeURIComponent(config.topic)}/sse?since=latest`;
  eventSource = new EventSource(streamUrl);
  eventSource.onopen = () => setStatus("Live", "live");
  eventSource.onerror = () => setStatus("Offline", "offline");
  eventSource.onmessage = (event) => {
    try {
      const message = JSON.parse(event.data);
      const snapshot = JSON.parse(message.message);
      localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snapshot));
      renderSnapshot(snapshot);
      setStatus("Live", "live");
    } catch {
      // Ignore retained messages that are not Metria snapshots.
    }
  };
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const config = { server: normalizeServer(serverInput.value.trim()), topic: topicInput.value.trim() };
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
  connect(config);
});

document.querySelector("#changeTopic").addEventListener("click", () => {
  eventSource?.close();
  dashboard.hidden = true;
  setup.hidden = false;
  setStatus("Not connected", "idle");
});

const savedConfig = JSON.parse(localStorage.getItem(CONFIG_KEY) || "null");
const savedSnapshot = JSON.parse(localStorage.getItem(SNAPSHOT_KEY) || "null");
if (savedSnapshot) renderSnapshot(savedSnapshot);
if (savedConfig?.server && savedConfig?.topic) {
  serverInput.value = savedConfig.server;
  topicInput.value = savedConfig.topic;
  connect(savedConfig);
}

if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");
