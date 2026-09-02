import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AppSettings, ProviderKind, ProviderSourceChoice, ProviderSourceInfo, ProviderUsage, UsageWindow, WslPresence } from "../shared/types";
import { PRESENCE_CACHE_TTL_MS } from "../shared/types";
import { readCursorItem } from "./cursor-state";
import { providerPaths, type ProviderPaths } from "./provider-paths";
import { makeWslShell, type WslProviderPresence, type WslShell } from "./wsl";

const defaultPaths: ProviderPaths = providerPaths({ platform: process.platform, home: homedir(), env: process.env });

interface Provider {
  readonly kind: ProviderKind;
  readonly hint: string;
  hasHostCredentials(): boolean;
  fetchHost(): Promise<ProviderUsage>;
  fetchWsl(shell: WslShell, distro: string): Promise<ProviderUsage>;
}

export class ProviderService {
  private readonly providers: Provider[];
  private readonly presenceResults = new Map<string, { at: number; presence: WslProviderPresence }>();

  constructor(
    private readonly loadSettings: () => AppSettings,
    private readonly wsl: WslShell = makeWslShell(),
    paths: ProviderPaths = defaultPaths
  ) {
    this.providers = [new ClaudeProvider(paths), new CodexProvider(paths), new OpenCodeGoProvider(paths), new CursorProvider(paths)];
  }

  async fetch(enabled: ProviderKind[]): Promise<ProviderUsage[]> {
    const entries = await this.sources(enabled);
    return Promise.all(entries.map(async (entry) => {
      const provider = this.providerFor(entry.kind);
      const source = chooseSource(entry, entry.source);
      if (!source) return unavailable(entry.kind, provider.hint);
      try {
        return source.location === "wsl"
          ? await provider.fetchWsl(this.wsl, source.distro ?? "")
          : await provider.fetchHost();
      } catch (error) {
        return { ...unavailable(entry.kind, provider.hint), available: true, error: error instanceof Error ? error.message : "Unable to load usage." };
      }
    }));
  }

  async sources(kinds: ProviderKind[]): Promise<ProviderSourceInfo[]> {
    const saved = this.loadSettings().providerSource ?? {};
    const distros = await this.wsl.distros();
    const presences = new Map<string, WslProviderPresence>();
    for (const distro of distros) presences.set(distro, await this.presence(distro));
    return kinds.map((kind) => {
      const wsl: WslPresence[] = distros.map((distro) => ({ distro, present: presences.get(distro)?.[POPULATION_BY_KIND[kind]] ?? false }));
      const host = this.providerFor(kind).hasHostCredentials();
      const source = saved[kind] ?? null;
      const needsChoice = host && wsl.some((entry) => entry.present) && !source;
      return { kind, host, wsl, source, needsChoice };
    });
  }

  private providerFor(kind: ProviderKind): Provider {
    return this.providers.find((provider) => provider.kind === kind)!;
  }

  private async presence(distro: string): Promise<WslProviderPresence> {
    const cached = this.presenceResults.get(distro);
    if (cached && Date.now() - cached.at < PRESENCE_CACHE_TTL_MS) return cached.presence;
    const presence = await this.wsl.presence(distro);
    this.presenceResults.set(distro, { at: Date.now(), presence });
    return presence;
  }
}

const POPULATION_BY_KIND: Record<ProviderKind, keyof WslProviderPresence> = { Claude: "claude", Codex: "codex", "OpenCode Go": "openCode", Cursor: "cursor" };
const WSL_DIR_BY_KIND: Partial<Record<ProviderKind, string>> = { Codex: ".codex/sessions" };

/** Pick the data source for a provider given saved preference (if any) and presence. */
export function chooseSource(info: Pick<ProviderSourceInfo, "host" | "wsl">, saved: ProviderSourceChoice | null): ProviderSourceChoice | null {
  const wslSource = (): ProviderSourceChoice | null => {
    const present = info.wsl.find((entry) => entry.present);
    return present ? { location: "wsl", distro: present.distro } : null;
  };
  if (saved) {
    if (saved.location === "host") return info.host ? saved : wslSource();
    return info.wsl.some((entry) => entry.distro === saved.distro && entry.present) ? saved : info.host ? { location: "host" } : wslSource();
  }
  return info.host ? { location: "host" } : wslSource();
}

class ClaudeProvider implements Provider {
  readonly kind = "Claude" as const;
  readonly hint = "Run `claude auth login` in your terminal to create local Claude Code credentials, then refresh Metria.";
  constructor(private readonly paths: ProviderPaths) {}
  hasHostCredentials(): boolean { return existsSync(this.paths.claudeCredentials); }
  async fetchHost(): Promise<ProviderUsage> {
    // `readToken` parses JSON, so it needs the file's contents — passing the path made
    // every host fetch fail with "credentials were not found".
    return this.usage(this.readToken(readTextOrEmpty(this.paths.claudeCredentials)), parseClaudeAccount(readTextOrEmpty(this.paths.claudeConfig)));
  }
  async fetchWsl(shell: WslShell, distro: string): Promise<ProviderUsage> {
    let account: string | undefined;
    try { account = parseClaudeAccount(await shell.readFile(distro, ".claude.json")); } catch { /* No account file in this distro. */ }
    return this.usage(this.readToken(await shell.readFile(distro, ".claude/.credentials.json")), account);
  }
  private readToken(credentials: string): string | undefined {
    try {
      return (JSON.parse(credentials) as { claudeAiOauth?: { accessToken?: string } }).claudeAiOauth?.accessToken;
    } catch { return undefined; }
  }
  private async usage(token?: string, accountLabel?: string): Promise<ProviderUsage> {
    if (!token) throw new Error("Claude Code credentials were not found. Run `claude auth login`.");
    const data = JSON.parse(await requestWithRetry("https://api.anthropic.com/api/oauth/usage", { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" })) as { five_hour?: { utilization?: number; resets_at?: string }; seven_day?: { utilization?: number; resets_at?: string } };
    return loaded(this.kind, [
      { title: "Current session", percent: Number(data.five_hour?.utilization ?? 0), resetDate: data.five_hour?.resets_at ?? null },
      { title: "All models", percent: Number(data.seven_day?.utilization ?? 0), resetDate: data.seven_day?.resets_at ?? null }
    ], accountLabel ?? null);
  }
}

class CodexProvider implements Provider {
  readonly kind = "Codex" as const;
  readonly hint = "Sign in with Codex to create local session data.";
  constructor(private readonly paths: ProviderPaths) {}
  hasHostCredentials(): boolean { return existsSync(this.paths.codexAuth) || existsSync(this.paths.codexSessions); }
  async fetchHost(): Promise<ProviderUsage> {
    if (existsSync(this.paths.codexAuth)) {
      const remote = await openCodeRemoteUsage(readFileSync(this.paths.codexAuth, "utf8"));
      if (remote) return remote;
    }
    return this.localUsage(readFileSyncPathOrEmpty(this.paths.codexSessions));
  }
  async fetchWsl(shell: WslShell, distro: string): Promise<ProviderUsage> {
    let remote: ProviderUsage | undefined;
    try { remote = await openCodeRemoteUsage(await shell.readFile(distro, ".codex/auth.json")); } catch { /* No WSL auth file. */ }
    if (remote) return remote;
    const newest = await shell.newestJsonl(distro, WSL_DIR_BY_KIND.Codex!);
    if (!newest) return empty(this.kind);
    return this.localUsage(await shell.readFile(distro, newest));
  }
  private localUsage(content: string): ProviderUsage {
    const windows = parseSessionWindows(content);
    return windows.length ? loaded(this.kind, windows) : empty(this.kind);
  }
}

class OpenCodeGoProvider implements Provider {
  readonly kind = "OpenCode Go" as const;
  readonly hint = "Sign in to OpenCode Go to create a local API credential.";
  constructor(private readonly paths: ProviderPaths) {}
  hasHostCredentials(): boolean { return existsSync(this.paths.openCodeAuth); }
  async fetchHost(): Promise<ProviderUsage> { return this.usage(readFileSync(this.paths.openCodeAuth, "utf8")); }
  async fetchWsl(shell: WslShell, distro: string): Promise<ProviderUsage> { return this.usage(await shell.readFile(distro, ".local/share/opencode/auth.json")); }
  private async usage(auth: string): Promise<ProviderUsage> {
    const key = parseOpenCodeGoKey(auth);
    if (!key) throw new Error("OpenCode Go credentials were not found.");
    const data = await requestWithRetry("https://opencode.ai/zen/go/v1/usage", { Authorization: `Bearer ${key}` });
    const windows = parseOpenCodeGoWindows(data);
    return loaded(this.kind, windows, maskedKey(key));
  }
}

export function parseOpenCodeGoWindows(data: string): UsageWindow[] {
  const parsed = JSON.parse(data) as { usage?: Record<string, { percent?: number; resetsAt?: string; resets_at?: string }> };
  return [["Current session", "rolling"], ["This week", "weekly"], ["This month", "monthly"]].flatMap(([title, keyName]) => {
    const limit = parsed.usage?.[keyName as string];
    return limit ? [{ title, percent: Number(limit.percent ?? 0), resetDate: limit.resetsAt ?? limit.resets_at ?? null }] : [];
  });
}

const CURSOR_TOKEN_KEY = "cursorAuth/accessToken";
const CURSOR_EMAIL_KEY = "cursorAuth/cachedEmail";
const CURSOR_USAGE_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
/** Without `includePooledUsage`, a team or enterprise account gets a stub answer
 * back — no `planUsage`, no `spendLimitUsage`, and a billing cycle whose start
 * and end are the same instant — which read as "this account has no usage".
 * The flag is what makes the server fill in the seat's real spend and limit. */
const CURSOR_USAGE_BODY = JSON.stringify({ includePooledUsage: true });

/** Reads the JWT Cursor stores in its VS Code-derived global storage and calls
 * the same endpoint the Cursor dashboard uses. Host-only: see
 * plans/003-cursor-provider-electron.md for why WSL is deferred. */
class CursorProvider implements Provider {
  readonly kind = "Cursor" as const;
  readonly hint = "Sign in to Cursor to make usage available.";
  constructor(private readonly paths: ProviderPaths) {}
  hasHostCredentials(): boolean { return existsSync(this.paths.cursorState) && readCursorItem(this.paths.cursorState, CURSOR_TOKEN_KEY) !== undefined; }
  async fetchHost(): Promise<ProviderUsage> {
    const token = readCursorItem(this.paths.cursorState, CURSOR_TOKEN_KEY);
    if (!token) throw new Error("Cursor credentials were not found. Sign in to Cursor, then refresh Metria.");
    if (isExpiredJwt(token)) throw new Error("Sign in to Cursor again.");
    try {
      const data = await requestWithRetry(CURSOR_USAGE_URL, {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1"
      }, { method: "POST", body: CURSOR_USAGE_BODY });
      return loaded(this.kind, parseCursorWindows(data), readCursorItem(this.paths.cursorState, CURSOR_EMAIL_KEY) ?? null);
    } catch (error) {
      // There is no refresh grant to use, so an unauthorized token is a sign-in prompt.
      if (error instanceof HttpError && (error.status === 401 || error.status === 403)) throw new Error("Sign in to Cursor again.");
      throw error;
    }
  }
  async fetchWsl(): Promise<ProviderUsage> {
    throw new Error("Cursor usage is read from the Windows or Linux host installation.");
  }
}

interface CursorUsageResponse {
  planUsage?: { includedSpend?: number; limit?: number; totalPercentUsed?: number } | null;
  spendLimitUsage?: { individualUsed?: number; individualLimit?: number; overallUsed?: number; overallLimit?: number } | null;
  billingCycleEnd?: string;
}

export function parseCursorWindows(data: string): UsageWindow[] {
  let parsed: CursorUsageResponse;
  try {
    parsed = JSON.parse(data) as CursorUsageResponse;
  } catch {
    throw new Error("Cursor returned an unreadable usage response.");
  }
  const measure = cursorMeasure(parsed);
  if (measure === undefined) throw new Error("Cursor did not report plan usage for this account.");
  const cycleEnd = Number(parsed.billingCycleEnd);
  return [{ title: "This cycle", ...measure, resetDate: Number.isFinite(cycleEnd) && cycleEnd > 0 ? new Date(cycleEnd).toISOString() : null }];
}

/** Follows the order Cursor's own usage bar uses: a plan with a real included
 * limit is measured against that limit, and an account whose quota lives in a
 * seat spend limit — team and enterprise seats, which report a `planUsage` of
 * all zeroes — is measured against the seat's individual, then overall, limit.
 * Every amount Cursor sends is in cents, and the pair that produced the percent
 * travels with it so a card can print "$130 / $250" for the same bar. The last
 * fallback is a bare percentage, which carries no amounts to show. */
function cursorMeasure(parsed: CursorUsageResponse): { percent: number; usedCents?: number; limitCents?: number } | undefined {
  const spent = (used?: number, limit?: number): { percent: number; usedCents: number; limitCents: number } | undefined =>
    typeof used === "number" && typeof limit === "number" && limit > 0
      ? { percent: Math.min((used / limit) * 100, 100), usedCents: used, limitCents: limit }
      : undefined;
  const plan = parsed.planUsage;
  const spend = parsed.spendLimitUsage;
  return spent(plan?.includedSpend, plan?.limit)
    ?? spent(spend?.individualUsed, spend?.individualLimit)
    ?? spent(spend?.overallUsed, spend?.overallLimit)
    ?? (typeof plan?.totalPercentUsed === "number" ? { percent: plan.totalPercentUsed } : undefined);
}

/** Reads the JWT `exp` claim without verifying the signature: Metria only wants
 * to skip a pointless network call for a token it already knows has expired. */
export function isExpiredJwt(token: string, now: number = Date.now()): boolean {
  const segments = token.split(".");
  if (segments.length < 2) return false;
  try {
    const payload = JSON.parse(Buffer.from(segments[1], "base64url").toString("utf8")) as { exp?: number };
    return typeof payload.exp === "number" && payload.exp * 1000 < now;
  } catch { return false; }
}

const REQUEST_TIMEOUT_MS = 10_000;

interface RequestOptions { method?: string; body?: string }

async function fetchWithTimeout(url: string, headers: Record<string, string>, options?: RequestOptions): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    return await fetch(url, { method: options?.method ?? "GET", body: options?.body, headers: { ...headers, "User-Agent": "Metria-Electron/0.1" }, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/** Carries the HTTP status so a provider can translate it into its own wording. */
class HttpError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

function sleep(ms: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function requestWithRetry(url: string, headers: Record<string, string>, options?: RequestOptions): Promise<string> {
  let lastError: Error | undefined;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await fetchWithTimeout(url, headers, options);
      if (response.ok) return response.text();
      if (response.status === 429 && attempt < 2) {
        const retry = Math.min(Number(response.headers.get("Retry-After") ?? 2 ** (attempt + 1)) * 1000, 30_000);
        await sleep(Number.isFinite(retry) ? retry : 2000);
        continue;
      }
      throw new HttpError(response.status === 429 ? "The provider rate limited Metria. Try again shortly." : `The provider returned ${response.status}.`, response.status);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (attempt === 2) throw lastError;
    }
  }
  throw lastError ?? new Error("Unable to load usage.");
}

function parseOpenCodeGoKey(auth: string): string | undefined {
  try {
    return (JSON.parse(auth) as { "opencode-go"?: { key?: string } })["opencode-go"]?.key;
  } catch { return undefined; }
}

async function openCodeRemoteUsage(auth: string): Promise<ProviderUsage | undefined> {
  const parsed = parseCodexAuth(auth);
  if (!parsed) return undefined;
  try {
    const data = await requestWithRetry("https://chatgpt.com/backend-api/wham/usage", { Authorization: `Bearer ${parsed.access}`, "ChatGPT-Account-Id": parsed.accountId });
    const rateLimit = (JSON.parse(data) as { rate_limit?: { primary_window?: { used_percent?: number; reset_at?: number }; secondary_window?: { used_percent?: number; reset_at?: number } } }).rate_limit;
    if (!rateLimit) return undefined;
    return loaded("Codex", [["Current session", rateLimit.primary_window], ["All models", rateLimit.secondary_window]].flatMap(([title, limit]) => {
      const typed = limit as { used_percent?: number; reset_at?: number } | undefined;
      return typed?.used_percent === undefined ? [] : [{ title: String(title), percent: Number(typed.used_percent), resetDate: typed.reset_at ? new Date(typed.reset_at * 1000).toISOString() : null }];
    }), parsed.email ?? null);
  } catch { return undefined; }
}

export function parseCodexAuth(auth: string): { access: string; accountId: string; email?: string } | undefined {
  try {
    const parsed = JSON.parse(auth) as {
      openai?: { access?: string; accountId?: string };
      tokens?: { access_token?: string; account_id?: string; id_token?: string };
    };
    // The id token is the one that carries the account's email; the access token is the
    // fallback for older auth files that store only it.
    if (parsed.tokens?.access_token && parsed.tokens.account_id) {
      return { access: parsed.tokens.access_token, accountId: parsed.tokens.account_id, email: (parsed.tokens.id_token ? tokenEmail(parsed.tokens.id_token) : undefined) ?? tokenEmail(parsed.tokens.access_token) };
    }
    return parsed.openai?.access && parsed.openai.accountId ? { access: parsed.openai.access, accountId: parsed.openai.accountId, email: tokenEmail(parsed.openai.access) } : undefined;
  } catch { return undefined; }
}

function parseSessionWindows(content: string): UsageWindow[] {
  const lines = content.trim().split("\n").reverse();
  for (const line of lines) {
    try {
      const value = JSON.parse(line) as { payload?: { rate_limits?: Record<string, { used_percent?: number; resets_at?: number }>; info?: { rate_limits?: Record<string, { used_percent?: number; resets_at?: number }> } } };
      const limits = value.payload?.rate_limits ?? value.payload?.info?.rate_limits;
      if (limits) {
        const windows = [["Current session", limits.primary], ["All models", limits.secondary]].flatMap(([title, limit]) => {
          const typed = limit as { used_percent?: number; resets_at?: number } | undefined;
          return typed?.used_percent === undefined ? [] : [{ title: String(title), percent: Number(typed.used_percent), resetDate: typed.resets_at ? new Date(typed.resets_at * 1000).toISOString() : null }];
        });
        if (windows.length) return windows;
      }
    } catch { /* Ignore malformed local event lines. */ }
  }
  return [];
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

/** A plain file read that treats "missing" and "unreadable" as empty, for the credential
 * and account files a provider may simply not have. */
function readTextOrEmpty(path: string): string {
  try { return existsSync(path) ? readFileSync(path, "utf8") : ""; } catch { return ""; }
}

function readFileSyncPathOrEmpty(path: string): string {
  const newest = newestSessionFile(path);
  return newest ? readFileSync(newest, "utf8") : "";
}

function loaded(kind: ProviderKind, windows: UsageWindow[], accountLabel: string | null = null): ProviderUsage {
  return { kind, accountLabel, windows, updatedAt: new Date().toISOString(), error: null, available: true, setupHint: "" };
}
function empty(kind: ProviderKind): ProviderUsage { return { ...loaded(kind, []), error: "No current usage data was found." }; }
function unavailable(kind: ProviderKind, setupHint: string): ProviderUsage { return { kind, accountLabel: null, windows: [], updatedAt: null, error: null, available: false, setupHint }; }

/** The email a token carries, read from the JWT payload without verifying the signature —
 * the same claims the native app looks at, in the same order. Claude's OAuth token is not
 * a JWT at all, which is why its email comes from `~/.claude.json` instead. */
export function tokenEmail(token: string): string | undefined {
  const segments = token.split(".");
  if (segments.length < 2) return undefined;
  try {
    const claims = JSON.parse(Buffer.from(segments[1], "base64url").toString("utf8")) as Record<string, unknown>;
    return ["email", "preferred_username", "unique_name"]
      .map((claim) => claims[claim])
      .find((value): value is string => typeof value === "string" && value.includes("@"));
  } catch { return undefined; }
}

/** Claude Code writes the signed-in account beside its credentials, in `~/.claude.json`. */
export function parseClaudeAccount(config: string): string | undefined {
  try {
    const email = (JSON.parse(config) as { oauthAccount?: { emailAddress?: string } }).oauthAccount?.emailAddress;
    return typeof email === "string" && email.length > 0 ? email : undefined;
  } catch { return undefined; }
}

/** An API key is not an identity, but it is what OpenCode Go has; mask it the way the
 * native app does so the card can still say which credential is in use. */
export function maskedKey(key: string): string {
  return key.length > 8 ? `${key.slice(0, 4)}...${key.slice(-4)}` : "****";
}
