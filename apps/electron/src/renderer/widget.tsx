import { useEffect, useRef, useState, type JSX } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { clampPercent, DEFAULT_WIDGET_SIZE, DEFAULT_WIDGET_Y_OFFSET, gaugeColor, PROVIDER_LOGOS, WIDGET_COLLAPSED_WIDTH, WIDGET_METRICS } from "../shared/types";
import type { ProviderKind, ProviderUsage, WidgetMetrics } from "../shared/types";
import "./app.css";

const queryClient = new QueryClient({ defaultOptions: { queries: { refetchOnWindowFocus: false } } });

const ACCENT: Record<ProviderKind, string> = {
  "Claude": "#ff9f0a",
  "Codex": "#0a84ff",
  "OpenCode Go": "#ffffff",
  "Cursor": "#8e8e93"
};

function primary(provider: ProviderUsage): number { return provider.windows[0]?.percent ?? 0; }

function Ring({ provider, size }: { provider: ProviderUsage; size: number }): JSX.Element {
  const clamped = clampPercent(primary(provider));
  const r = 17;
  const c = 2 * Math.PI * r;
  const stroke = provider.kind === "Codex" ? "url(#codex-ring)" : ACCENT[provider.kind];
  return (
    <span className="relative block" style={{ height: size, width: size }}>
      <svg className="absolute inset-0" width={size} height={size} viewBox="0 0 38 38">
        {provider.kind === "Codex" && (
          <defs>
            <linearGradient id="codex-ring" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stopColor="#0a84ff" />
              <stop offset="1" stopColor="#bf5af2" />
            </linearGradient>
          </defs>
        )}
        <circle cx="19" cy="19" r={r} fill="none" stroke="#2c2c2c" strokeWidth="5" />
        <circle
          cx="19" cy="19" r={r} fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round"
          strokeDasharray={`${c.toFixed(2)} ${c.toFixed(2)}`}
          strokeDashoffset={(c * (1 - clamped / 100)).toFixed(2)}
          transform="rotate(-90 19 19)"
        />
      </svg>
      <img className="pointer-events-none absolute inset-0 m-auto object-contain" style={{ height: size * 0.4, width: size * 0.4 }} src={`./${PROVIDER_LOGOS[provider.kind]}`} alt="" />
    </span>
  );
}

const DRAG_THRESHOLD = 4;

/** The rail is as wide as its window: in hover mode the main process shrinks that window
 * to a sliver, and this is how the renderer notices it has to draw one. */
function useCollapsed(): boolean {
  const [collapsed, setCollapsed] = useState(window.innerWidth <= WIDGET_COLLAPSED_WIDTH + 2);
  useEffect(() => {
    const onResize = (): void => setCollapsed(window.innerWidth <= WIDGET_COLLAPSED_WIDTH + 2);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return collapsed;
}

/** What the sliver shows: the worst reading, as a single stripe of its gauge color. */
function CollapsedRail({ providers }: { providers: ProviderUsage[] }): JSX.Element {
  const worst = providers.reduce((highest, provider) => Math.max(highest, clampPercent(primary(provider))), 0);
  return (
    <main
      className="h-full w-full cursor-pointer"
      style={{ background: providers.length ? gaugeColor(worst) : "#3a3a3c" }}
      onMouseEnter={() => { void window.metria.setWidgetHover(true); }}
    />
  );
}

function Widget(): JSX.Element {
  // The dashboard can enable/disable providers at any time; refresh our cached
  // settings/usage as soon as the main process broadcasts a change so the notch
  // picks up the new provider immediately instead of waiting for the poll cycle.
  useEffect(() => {
    window.metria.onSettingsChanged(() => { void queryClient.invalidateQueries(); });
  }, []);
  const settings = useQuery({ queryKey: ["settings"], queryFn: () => window.metria.getSettings() });
  const usage = useQuery({
    queryKey: ["usage"],
    queryFn: () => window.metria.getUsage(),
    refetchInterval: settings.data ? settings.data.refreshIntervalSeconds * 1000 : undefined
  });
  const collapsed = useCollapsed();
  const drag = useRef<{ startScreenY: number; startOffset: number } | null>(null);
  const moved = useRef(false);
  const offsetRef = useRef(DEFAULT_WIDGET_Y_OFFSET);
  const pendingTarget = useRef<number | null>(null);
  const frameScheduled = useRef(false);
  const scheduleMove = (target: number): void => {
    pendingTarget.current = target;
    if (frameScheduled.current) return;
    frameScheduled.current = true;
    requestAnimationFrame(() => {
      frameScheduled.current = false;
      const value = pendingTarget.current;
      pendingTarget.current = null;
      if (value === null) return;
      // Keep the drag base in sync with the persisted (clamped) value so each
      // new drag starts from the widget's actual position instead of a stale one.
      void window.metria.setWidgetYOffset(value).then((settings) => { offsetRef.current = settings.widgetYOffset; });
    });
  };
  const visible = (usage.data ?? []).filter((provider) => settings.data?.enabledProviders.includes(provider.kind) && provider.available);
  const metrics: WidgetMetrics = WIDGET_METRICS[settings.data?.widgetSize ?? DEFAULT_WIDGET_SIZE];
  if (collapsed) return <CollapsedRail providers={visible} />;
  const onPointerDown = (event: React.PointerEvent<HTMLElement>): void => {
    moved.current = false;
    // Use screenY, not clientY: the widget window moves while dragging, so
    // viewport-relative coordinates shift on their own and make the drag
    // oscillate (ghost effect). screenY is global and stays stable.
    drag.current = { startScreenY: event.screenY, startOffset: offsetRef.current };
    event.currentTarget.setPointerCapture(event.pointerId);
  };
  const onPointerMove = (event: React.PointerEvent<HTMLElement>): void => {
    const dragState = drag.current;
    if (!dragState) return;
    const delta = Math.round(event.screenY - dragState.startScreenY);
    if (Math.abs(delta) > DRAG_THRESHOLD) {
      if (!moved.current) void window.metria.setProviderHover(null);
      moved.current = true;
      scheduleMove(dragState.startOffset + delta);
    }
  };
  const onPointerUp = (event: React.PointerEvent<HTMLElement>): void => {
    drag.current = null;
    try { event.currentTarget.releasePointerCapture(event.pointerId); } catch { /* Not captured. */ }
    if (moved.current) {
      // The widget moved while dragging; re-assess the hover so the card shows
      // again for the item now under the cursor instead of staying stale/hidden.
      const hit = document.elementsFromPoint(event.clientX, event.clientY)
        .find((element) => element instanceof HTMLElement && element.dataset.index !== undefined);
      void window.metria.setProviderHover(hit instanceof HTMLElement ? Number(hit.dataset.index) : null);
    }
  };
  return (
    <main
      className="flex h-full w-full cursor-grab select-none flex-col overflow-hidden active:cursor-grabbing"
      style={{ paddingTop: metrics.padding, paddingBottom: metrics.padding }}
      onMouseEnter={() => { void window.metria.setWidgetHover(true); }}
      onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}
    >
      <section className="flex min-h-0 flex-1 flex-col items-center" style={{ gap: metrics.gap }}>
        {visible.map((provider, index) => (
          <div
            key={provider.kind}
            data-index={index}
            className="flex shrink-0 cursor-pointer flex-col items-center justify-center gap-[3px]"
            style={{ height: metrics.itemHeight, width: metrics.width - 2 * metrics.padding }}
            onClick={() => { if (!moved.current) void window.metria.openDashboard(); }}
            onMouseEnter={() => { void window.metria.setProviderHover(index); }}
          >
            <Ring provider={provider} size={metrics.ring} />
            <span className="font-semibold leading-none text-white" style={{ fontSize: Math.round(metrics.ring * 0.29) }}>
              {Math.round(clampPercent(primary(provider)))}%
            </span>
          </div>
        ))}
      </section>
    </main>
  );
}

function Root(): JSX.Element {
  return (
    <QueryClientProvider client={queryClient}>
      <Widget />
    </QueryClientProvider>
  );
}

document.body.addEventListener("mouseleave", () => {
  void window.metria.setProviderHover(null);
  void window.metria.setWidgetHover(false);
});
createRoot(document.body).render(<Root />);
