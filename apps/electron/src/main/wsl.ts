import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const WSL_TIMEOUT_MS = 15_000;
const RESULT_TTL_MS = 30_000;

export interface WslExec {
  (command: string, args: string[]): Promise<{ stdout: string }>;
}

export interface WslProviderPresence {
  codex: boolean;
  openCode: boolean;
  claude: boolean;
}

export interface WslShell {
  distros(): Promise<string[]>;
  presence(distro: string): Promise<WslProviderPresence>;
  readFile(distro: string, homeRelativePath: string): Promise<string>;
  newestJsonl(distro: string, homeRelativeDir: string): Promise<string | undefined>;
}

export function makeWslShell(options: { platform?: NodeJS.Platform; exec?: WslExec; results?: Map<string, { at: number; presence: WslProviderPresence }> } = {}): WslShell {
  const platform = options.platform ?? process.platform;
  const exec = options.exec ?? (execFileAsync as unknown as WslExec);
  const results = options.results ?? new Map<string, { at: number; presence: WslProviderPresence }>();

  function run(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("WSL command timed out.")), WSL_TIMEOUT_MS);
      exec("wsl.exe", args)
        .then((result) => resolve(result.stdout))
        .catch(reject)
        .finally(() => clearTimeout(timeout));
    });
  }

  async function distros(): Promise<string[]> {
    if (platform !== "win32") return [];
    try {
      const stdout = await run(["--list", "--quiet"]);
      return stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    } catch {
      return [];
    }
  }

  async function presence(distro: string): Promise<WslProviderPresence> {
    if (platform !== "win32") return { codex: false, openCode: false, claude: false };
    const cached = results.get(distro);
    if (cached && Date.now() - cached.at < RESULT_TTL_MS) return cached.presence;
    const script = [
      'for f in codex_auth:"$HOME/.codex/auth.json" codex_sessions:"$HOME/.codex/sessions" opencode:"$HOME/.local/share/opencode/auth.json" claude:"$HOME/.claude/.credentials.json"; do',
      '  name="${f%%:*}"; target="${f#*:}"',
      '  if [ -e "$target" ]; then echo "$name"; fi',
      "done"
    ].join(" ");
    try {
      const stdout = await run(["-d", distro, "sh", "-c", script]);
      const hits = stdout.split(/\r?\n/).map((line) => line.trim());
      const presence: WslProviderPresence = {
        codex: hits.includes("codex_auth") || hits.includes("codex_sessions"),
        openCode: hits.includes("opencode"),
        claude: hits.includes("claude")
      };
      results.set(distro, { at: Date.now(), presence });
      return presence;
    } catch {
      return { codex: false, openCode: false, claude: false };
    }
  }

  function readFile(distro: string, homeRelativePath: string): Promise<string> {
    const script = `cat "$HOME/${homeRelativePath}"`;
    return run(["-d", distro, "sh", "-c", script]);
  }

  async function newestJsonl(distro: string, homeRelativeDir: string): Promise<string | undefined> {
    const script = [
      `candidate=$(find "$HOME/${homeRelativeDir}" -name '*.jsonl' -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -1)`,
      '[ -n "$candidate" ] && echo "${candidate#* }" | sed "s|^$HOME/||" || true'
    ].join("; ");
    try {
      const stdout = (await run(["-d", distro, "sh", "-c", script])).trim();
      return stdout || undefined;
    } catch {
      return undefined;
    }
  }

  return { distros, presence, readFile, newestJsonl };
}
