import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ProviderKind, ProviderUsage, UsageWindow } from "../shared/types";
import { providerPaths } from "./provider-paths";

const paths = providerPaths({ platform: process.platform, home: homedir(), env: process.env });
const authPath = paths.openCodeAuth;
const codexSessionsPath = paths.codexSessions;
const execFileAsync = promisify(execFile);

interface Provider { kind: ProviderKind; available(): boolean; fetch(): Promise<ProviderUsage>; hint: string; }

export class ProviderService {
  private readonly providers: Provider[] = [new ClaudeProvider(), new CodexProvider(), new OpenCodeGoProvider()];

  async fetch(enabled: ProviderKind[]): Promise<ProviderUsage[]> {
    if (process.env.METRIA_SYNTHETIC === "1") return enabled.map((kind, index) => loaded(kind, [{ title: "Synthetic session", percent: [32, 58, 76][index] ?? 0, resetDate: new Date(Date.now() + 3_600_000).toISOString() }]));
    return Promise.all(this.providers.filter((provider) => enabled.includes(provider.kind)).map(async (provider) => {
      if (!provider.available()) return unavailable(provider.kind, provider.hint);
      try { return await provider.fetch(); }
      catch (error) { return { ...unavailable(provider.kind, provider.hint), available: true, error: error instanceof Error ? error.message : "Unable to load usage." }; }
    }));
  }
}

class ClaudeProvider implements Provider {
  readonly kind = "Claude" as const;
  readonly hint = process.platform === "darwin" ? "Run `claude auth login` to store Claude Code credentials in your macOS Keychain." : "Claude usage in Electron currently supports the macOS Claude Code Keychain. Use the native Mac app or run Claude Code on this platform.";
  available(): boolean { return process.platform === "darwin"; }
  async fetch(): Promise<ProviderUsage> {
    if (process.platform !== "darwin") return unavailable(this.kind, this.hint);
    const { stdout } = await execFileAsync("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]);
    const credential = JSON.parse(stdout) as { claudeAiOauth?: { accessToken?: string } };
    const token = credential.claudeAiOauth?.accessToken;
    if (!token) throw new Error("Claude Code credentials were not found. Run `claude auth login`.");
    const data = await requestWithRetry("https://api.anthropic.com/api/oauth/usage", { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" });
    const usage = JSON.parse(data) as { five_hour?: { utilization?: number; resets_at?: string }; seven_day?: { utilization?: number; resets_at?: string } };
    return loaded(this.kind, [
      { title: "Current session", percent: Number(usage.five_hour?.utilization ?? 0), resetDate: usage.five_hour?.resets_at ?? null },
      { title: "All models", percent: Number(usage.seven_day?.utilization ?? 0), resetDate: usage.seven_day?.resets_at ?? null }
    ]);
  }
}

class CodexProvider implements Provider {
  readonly kind = "Codex" as const;
  readonly hint = "Sign in with Codex to create local session data.";
  available(): boolean { return existsSync(authPath) || existsSync(codexSessionsPath); }
  async fetch(): Promise<ProviderUsage> {
    const remote = await this.fetchOpenCodeUsage();
    if (remote) return remote;
    const newest = newestSessionFile(codexSessionsPath);
    if (!newest) return empty(this.kind);
    const lines = readFileSync(newest, "utf8").trim().split("\n").reverse();
    for (const line of lines) {
      try {
        const value = JSON.parse(line) as { payload?: { rate_limits?: Record<string, { used_percent?: number; resets_at?: number }>; info?: { rate_limits?: Record<string, { used_percent?: number; resets_at?: number }> } } };
        const limits = value.payload?.rate_limits ?? value.payload?.info?.rate_limits;
        if (limits) {
          const windows = [["Current session", limits.primary], ["All models", limits.secondary]].flatMap(([title, limit]) => {
            const typed = limit as { used_percent?: number; resets_at?: number } | undefined;
            return typed?.used_percent === undefined ? [] : [{ title: String(title), percent: Number(typed.used_percent), resetDate: typed.resets_at ? new Date(typed.resets_at * 1000).toISOString() : null }];
          });
          if (windows.length) return loaded(this.kind, windows);
        }
      } catch { /* Ignore malformed local event lines. */ }
    }
    return empty(this.kind);
  }
  private async fetchOpenCodeUsage(): Promise<ProviderUsage | undefined> {
    if (!existsSync(authPath)) return undefined;
    try {
      const auth = JSON.parse(readFileSync(authPath, "utf8")) as { openai?: { access?: string; accountId?: string } };
      const access = auth.openai?.access; const accountId = auth.openai?.accountId;
      if (!access || !accountId) return undefined;
      const data = await requestWithRetry("https://chatgpt.com/backend-api/wham/usage", { Authorization: `Bearer ${access}`, "ChatGPT-Account-Id": accountId });
      const rateLimit = (JSON.parse(data) as { rate_limit?: { primary_window?: { used_percent?: number; reset_at?: number }; secondary_window?: { used_percent?: number; reset_at?: number } } }).rate_limit;
      if (!rateLimit) return undefined;
      return loaded(this.kind, [["Current session", rateLimit.primary_window], ["All models", rateLimit.secondary_window]].flatMap(([title, limit]) => {
        const typed = limit as { used_percent?: number; reset_at?: number } | undefined;
        return typed?.used_percent === undefined ? [] : [{ title: String(title), percent: Number(typed.used_percent), resetDate: typed.reset_at ? new Date(typed.reset_at * 1000).toISOString() : null }];
      }));
    } catch { return undefined; }
  }
}

class OpenCodeGoProvider implements Provider {
  readonly kind = "OpenCode Go" as const;
  readonly hint = "Sign in to OpenCode Go to create a local API credential.";
  available(): boolean { return existsSync(authPath); }
  async fetch(): Promise<ProviderUsage> {
    const auth = JSON.parse(readFileSync(authPath, "utf8")) as { "opencode-go"?: { key?: string } };
    const key = auth["opencode-go"]?.key;
    if (!key) throw new Error("OpenCode Go credentials were not found.");
    const data = JSON.parse(await requestWithRetry("https://opencode.ai/zen/go/v1/usage", { Authorization: `Bearer ${key}` })) as { usage?: Record<string, { percent?: number; resets_at?: string }> };
    const windows = [["Current session", "rolling"], ["This week", "weekly"], ["This month", "monthly"]].flatMap(([title, keyName]) => {
      const limit = data.usage?.[keyName];
      return limit ? [{ title, percent: Number(limit.percent ?? 0), resetDate: limit.resets_at ?? null }] : [];
    });
    return loaded(this.kind, windows);
  }
}

const REQUEST_TIMEOUT_MS = 10_000;

async function fetchWithTimeout(url: string, headers: Record<string, string>): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    return await fetch(url, { headers: { ...headers, "User-Agent": "Metria-Desktop/0.1" }, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function sleep(ms: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function requestWithRetry(url: string, headers: Record<string, string>): Promise<string> {
  let lastError: Error | undefined;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await fetchWithTimeout(url, headers);
      if (response.ok) return response.text();
      if (response.status === 429 && attempt < 2) {
        const retry = Math.min(Number(response.headers.get("Retry-After") ?? 2 ** (attempt + 1)) * 1000, 30_000);
        await sleep(Number.isFinite(retry) ? retry : 2000);
        continue;
      }
      throw new Error(response.status === 429 ? "The provider rate limited Metria. Try again shortly." : `The provider returned ${response.status}.`);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (attempt === 2) throw lastError;
    }
  }
  throw lastError ?? new Error("Unable to load usage.");
}

function newestSessionFile(path: string): string | undefined {
  if (!existsSync(path)) return undefined;
  const files: { path: string; modified: number }[] = [];
  const visit = (directory: string) => readdirSync(directory, { withFileTypes: true }).forEach((entry) => {
    const candidate = join(directory, entry.name);
    if (entry.isDirectory()) visit(candidate);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) files.push({ path: candidate, modified: statSync(candidate).mtimeMs });
  });
  visit(path);
  return files.sort((left, right) => right.modified - left.modified)[0]?.path;
}

function loaded(kind: ProviderKind, windows: UsageWindow[]): ProviderUsage { return { kind, windows, updatedAt: new Date().toISOString(), error: null, available: true, setupHint: "" }; }
function empty(kind: ProviderKind): ProviderUsage { return { ...loaded(kind, []), error: "No current usage data was found." }; }
function unavailable(kind: ProviderKind, setupHint: string): ProviderUsage { return { kind, windows: [], updatedAt: null, error: null, available: false, setupHint }; }
