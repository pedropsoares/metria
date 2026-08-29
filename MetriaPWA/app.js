const CONFIG_KEY = "metriaPwaConfig";
const SNAPSHOT_KEY = "metriaPwaSnapshot";
let eventSource;
let activeCryptoKey;

const setup = document.querySelector("#setup");
const dashboard = document.querySelector("#dashboard");
const form = document.querySelector("#topicForm");
const serverInput = document.querySelector("#serverInput");
const phraseInput = document.querySelector("#phraseInput");
const pairingError = document.querySelector("#pairingError");
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

// Connects to the ntfy topic derived from the paired secret and decrypts every message
// that arrives. A message that fails to decrypt (wrong key, or forged noise sent by
// someone who merely guessed the topic name) is silently ignored.
async function connect(config) {
  eventSource?.close();
  setup.hidden = true;
  dashboard.hidden = false;
  setStatus("Connecting", "connecting");

  const secretBytes = window.MetriaPairing.base64UrlToBytes(config.secretBase64);
  const { topic, cryptoKey } = await window.MetriaPairing.deriveFromSecret(secretBytes);
  activeCryptoKey = cryptoKey;

  const streamUrl = `${normalizeServer(config.server)}/${topic}/sse?since=latest`;
  eventSource = new EventSource(streamUrl);
  eventSource.onopen = () => setStatus("Live", "live");
  eventSource.onerror = () => setStatus("Offline", "offline");
  eventSource.onmessage = async (event) => {
    try {
      const message = JSON.parse(event.data);
      const snapshot = await window.MetriaPairing.decryptSnapshot(message.message, activeCryptoKey);
      localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snapshot));
      renderSnapshot(snapshot);
      setStatus("Live", "live");
    } catch {
      // Not a valid encrypted snapshot for our key — ignore it.
    }
  };
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  pairingError.hidden = true;

  const words = phraseInput.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const secretBytes = await window.MetriaPairing.wordsToSecret(words);
  if (!secretBytes) {
    pairingError.hidden = false;
    return;
  }

  const config = {
    secretBase64: window.MetriaPairing.bytesToBase64Url(secretBytes),
    server: normalizeServer(serverInput.value.trim() || "https://ntfy.sh")
  };
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
  connect(config);
});

document.querySelector("#changeTopic").addEventListener("click", () => {
  eventSource?.close();
  dashboard.hidden = true;
  setup.hidden = false;
  setStatus("Not connected", "idle");
});

// Reads a pairing link's fragment (e.g. from scanning the Mac app's QR code). The
// fragment never reaches any server — it's stripped from the visible URL immediately
// after reading it, so the secret doesn't linger in browser history.
function readPairingFromHash() {
  if (!location.hash) return null;
  const params = new URLSearchParams(location.hash.slice(1));
  const secretBase64 = params.get("s");
  if (!secretBase64) return null;
  const server = params.get("server") ? decodeURIComponent(params.get("server")) : "https://ntfy.sh";
  history.replaceState(null, "", location.pathname + location.search);
  return { secretBase64, server };
}

const hashConfig = readPairingFromHash();
const savedSnapshot = JSON.parse(localStorage.getItem(SNAPSHOT_KEY) || "null");
if (savedSnapshot) renderSnapshot(savedSnapshot);

if (hashConfig) {
  localStorage.setItem(CONFIG_KEY, JSON.stringify(hashConfig));
  connect(hashConfig);
} else {
  const savedConfig = JSON.parse(localStorage.getItem(CONFIG_KEY) || "null");
  if (savedConfig?.secretBase64) {
    serverInput.value = savedConfig.server;
    connect(savedConfig);
  }
}

if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");
