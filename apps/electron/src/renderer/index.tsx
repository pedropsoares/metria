import { useEffect, useState, type JSX } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider, useMutation, useQuery } from "@tanstack/react-query";
import type { ProviderKind, ProviderUsage, UsageWindow } from "../shared/types";
import "./app.css";

const queryClient = new QueryClient({ defaultOptions: { queries: { refetchOnWindowFocus: false } } });

const LOGO: Record<ProviderKind, string> = { Claude: "claude-logo.png", Codex: "codex-logo.png", "OpenCode Go": "opencode-logo.png" };

function percentage(value: number): string { return `${Math.max(0, Math.min(100, value)).toFixed(0)}%`; }
function date(value: string | null): string { return value ? `Resets ${new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))}` : "No reset time available"; }
function gaugeColor(percent: number): string { return percent >= 85 ? "#ff453a" : percent >= 65 ? "#ff9f0a" : percent >= 40 ? "#ffd60a" : "#30d158"; }

function UsageRow({ window: row }: { window: UsageWindow }): JSX.Element {
  return (
    <div className="mt-[18px] first:mt-0">
      <div className="flex justify-between gap-4">
        <span>{row.title}</span>
        <strong className="font-mono text-lg">{percentage(row.percent)}</strong>
      </div>
      <div className="my-[9px] h-2 overflow-hidden rounded-[99px] bg-[#1c1c1e]">
        <i className="block h-full rounded-[99px]" style={{ background: gaugeColor(row.percent), width: percentage(row.percent) }} />
      </div>
      <small className="text-dim">{date(row.resetDate)}</small>
    </div>
  );
}

function ProviderCard({ provider, enabled, onStatus }: { provider: ProviderUsage; enabled: boolean; onStatus: (message: string) => void }): JSX.Element {
  const setEnabled = useMutation({
    mutationFn: (value: boolean) => window.metria.setProviderEnabled(provider.kind, value),
    onSuccess: (settings) => {
      queryClient.setQueryData(["settings"], settings);
      void queryClient.invalidateQueries({ queryKey: ["usage"] });
    }
  });
  const setup = useMutation({
    mutationFn: () => window.metria.reconnect(provider.kind),
    onSuccess: (result) => onStatus(result.message)
  });
  const pending = setEnabled.isPending || setup.isPending;
  const onClick = (): void => {
    if (!enabled) setEnabled.mutate(true);
    else if (provider.available) setEnabled.mutate(false);
    else setup.mutate();
  };
  return (
    <article className={`my-3.5 px-3 py-4 ${enabled ? "" : "opacity-60"}`}>
      <div className="flex items-center justify-between gap-[18px]">
        <div className="flex items-center gap-2.5">
          <img className="h-[22px] w-[22px] object-contain" src={`./${LOGO[provider.kind]}`} alt="" />
          <h2 className="m-0 text-xl font-semibold">{provider.kind}</h2>
          <span className="h-[7px] w-[7px] shrink-0 rounded-full" style={{ background: provider.error ? "#ff9f0a" : "#30d158" }} />
        </div>
        <button
          type="button"
          className="cursor-pointer border border-line2 bg-transparent px-3 py-[7px] text-[#d8d8dc] disabled:opacity-55"
          onClick={onClick}
          disabled={pending}
        >
          {!enabled ? "Enable" : provider.available ? "Disable" : "Setup"}
        </button>
      </div>
      {!provider.available && <p className="m-0 mt-4 leading-relaxed text-dim">{provider.setupHint}</p>}
      {provider.error && <p className="m-0 mt-4 leading-relaxed text-dim">{provider.error}</p>}
      {provider.windows.map((row) => <UsageRow key={row.title} window={row} />)}
    </article>
  );
}

function Dashboard(): JSX.Element {
  const [status, setStatus] = useState("Loading provider usage…");
  const usage = useQuery({
    queryKey: ["usage"],
    queryFn: () => window.metria.refresh()
  });
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => window.metria.getSettings()
  });
  useEffect(() => {
    if (usage.isFetching) setStatus("Refreshing usage…");
    else if (usage.isError) setStatus("Metria could not refresh usage.");
    else if (usage.isSuccess) setStatus(`Updated ${new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(new Date())}`);
  }, [usage.status, usage.isFetching, usage.isSuccess, usage.isError]);
  return (
    <main className="mx-auto max-w-[880px] px-[clamp(24px,5vw,56px)] py-[clamp(24px,5vw,56px)]">
      <header className="flex items-center justify-between gap-6 border-b border-line pb-[22px]">
        <h1 className="m-0 text-[clamp(28px,4.6vw,46px)] leading-none tracking-[-0.07em]">
          <img className="mr-2.5 inline h-10 w-10 object-contain align-[-7px]" src="./metria-logo.png" alt="Metria" />
          Metria
        </h1>
        <button
          type="button"
          aria-label="Refresh usage"
          className="cursor-pointer rounded-full bg-[#e8edf3] p-2.5 text-[#10151b] focus-visible:outline-[3px] focus-visible:outline-offset-[3px] focus-visible:outline-accent disabled:opacity-55"
          onClick={() => void usage.refetch()}
          disabled={usage.isFetching}
        >
          <svg aria-hidden="true" viewBox="0 0 512 512" fill="currentColor" className={`h-3.5 w-3.5 ${usage.isFetching ? "animate-spin" : ""}`}>
            <path d="M65.9 228.5c13.3-93 93.4-164.5 190.1-164.5 53 0 101 21.5 135.8 56.2 .2 .2 .4 .4 .6 .6l7.6 7.2-47.9 0c-17.7 0-32 14.3-32 32s14.3 32 32 32l128 0c17.7 0 32-14.3 32-32l0-128c0-17.7-14.3-32-32-32s-32 14.3-32 32l0 53.4-11.3-10.7C390.5 28.6 326.5 0 256 0 127 0 20.3 95.4 2.6 219.5 .1 237 12.2 253.2 29.7 255.7s33.7-9.7 36.2-27.1zm443.5 64c2.5-17.5-9.7-33.7-27.1-36.2s-33.7 9.7-36.2 27.1c-13.3 93-93.4 164.5-190.1 164.5-53 0-101-21.5-135.8-56.2-.2-.2-.4-.4-.6-.6l-7.6-7.2 47.9 0c17.7 0 32-14.3 32-32s-14.3-32-32-32L32 320c-8.5 0-16.7 3.4-22.7 9.5S-.1 343.7 0 352.3l1 127c.1 17.7 14.6 31.9 32.3 31.7S65.2 496.4 65 478.7l-.4-51.5 10.7 10.1c46.3 46.1 110.2 74.7 180.7 74.7 129 0 235.7-95.4 253.4-219.5z" />
          </svg>
        </button>
      </header>
      <p className="mb-[30px] mt-[18px] text-dim" role="status">{status}</p>
      <section aria-live="polite">
        {(usage.data ?? []).map((provider) => (
          <ProviderCard key={provider.kind} provider={provider} enabled={settings.data?.enabledProviders.includes(provider.kind) ?? true} onStatus={setStatus} />
        ))}
      </section>
    </main>
  );
}

function Root(): JSX.Element {
  return (
    <QueryClientProvider client={queryClient}>
      <Dashboard />
    </QueryClientProvider>
  );
}

createRoot(document.body).render(<Root />);
