import { useEffect, useState, type JSX } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import type { CardShowPayload, ProviderKind, ProviderUsage, UsageWindow } from "../shared/types";
import "./app.css";

const queryClient = new QueryClient({ defaultOptions: { queries: { refetchOnWindowFocus: false } } });

// The main process can emit `metria:card-show` before React mounts (first hover
// after the window is created); buffer the last payload so the effect can apply
// it immediately instead of waiting for the next hover.
type ShowListener = (payload: CardShowPayload | null) => void;
let bufferedShow: CardShowPayload | null = null;
const showListeners = new Set<ShowListener>();
window.metria.onCardShow((payload) => { bufferedShow = payload; showListeners.forEach((listener) => listener(payload)); });
window.metria.onCardHide(() => { bufferedShow = null; showListeners.forEach((listener) => listener(null)); });

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

function WindowRow({ window: row }: { window: UsageWindow }): JSX.Element {
  const percent = Math.max(0, Math.min(100, row.percent));
  return (
    <div className="mt-[18px] first:mt-0">
      <div className="flex items-baseline justify-between gap-3 text-[15px] leading-[1.2]">
        <span>{row.title}</span>
        <span className="whitespace-nowrap text-xs text-mute">{resetText(row.resetDate)}</span>
      </div>
      <div className="my-2 h-[7px] overflow-hidden rounded-[99px] bg-[#2c2c2c]">
        <i className="block h-full rounded-[99px]" style={{ background: gaugeColor(percent), width: `${percent}%` }} />
      </div>
      <div className="mt-2 text-[15px] font-semibold leading-none text-[#e8e8e8]">{Math.round(percent)}% Used</div>
    </div>
  );
}

function Card(): JSX.Element {
  const [payload, setPayload] = useState<CardShowPayload | null>(bufferedShow);
  const usage = useQuery({
    queryKey: ["usage"],
    queryFn: () => window.metria.getUsage(),
    refetchOnWindowFocus: false
  });
  const provider = usage.data?.find((candidate) => candidate.kind === payload?.kind);

  useEffect(() => {
    const apply = (next: CardShowPayload | null): void => setPayload(next);
    // Never re-send a hover from inside the card: it cancels the pending hide and
    // keeps the card open when the pointer merely crosses it while leaving the widget.
    const leave = (): void => { void window.metria.setProviderHover(null); };
    showListeners.add(apply);
    document.body.addEventListener("mouseleave", leave);
    return () => {
      showListeners.delete(apply);
      document.body.removeEventListener("mouseleave", leave);
    };
  }, []);

  useEffect(() => {
    if (!payload) return;
    requestAnimationFrame(() => { void window.metria.resizeCard(Math.ceil(document.body.scrollHeight)); });
  }, [payload, provider, usage.data]);

  const content = provider ? (
    provider.windows.length === 0 ? (
      <>
        <div className="flex items-center gap-2 text-[13px] leading-[1.4] text-mute">
          {provider.error ?? "Waiting for usage data..."}
        </div>
        {provider.error && <p className="mt-3 text-[12px] leading-[1.4] text-[#ff8d6c]">{provider.error}</p>}
      </>
    ) : (
      provider.windows.map((row) => <WindowRow key={row.title} window={row} />)
    )
  ) : (
    <div className="flex items-center gap-2 text-[13px] leading-[1.4] text-mute">Waiting for usage data...</div>
  );

  return (
    <main className="relative flex h-fit min-w-[316px] select-none flex-col bg-surface px-6 py-7">
      <h2 className="m-0 flex items-center gap-2.5 p-0 mb-5 text-[22px] font-medium leading-none">
        {provider && (
          <>
            <img className="h-[22px] w-[22px] shrink-0 object-contain" src={`./${KIND[provider.kind].logo}`} alt="" />
            <span>{KIND[provider.kind].label}</span>
            <span className="h-[7px] w-[7px] shrink-0 rounded-full" style={{ background: provider.error ? "#ff9f0a" : "#30d158" }} />
          </>
        )}
      </h2>
      <div>{content}</div>
    </main>
  );
}

function Root(): JSX.Element {
  return (
    <QueryClientProvider client={queryClient}>
      <Card />
    </QueryClientProvider>
  );
}

createRoot(document.body).render(<Root />);
