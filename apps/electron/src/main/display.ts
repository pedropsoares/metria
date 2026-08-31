export type DisplayMode = "tray" | "notch";

export interface WorkArea {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Side-notch metrics mirrored from the native macOS app (medium notch, scale = 1). */
export const NOTCH = {
  idleWidth: 80,
  compactHeight: 236,
  hoverHeight: 280,
  cornerRadius: 20,
  providerItemHeight: 64,
  providerSpacing: 10,
  cardWidth: 316,
  cardContentWidth: 300,
  pointerWidth: 16,
  cardSpacing: 12,
  hiddenWidth: 14,
  hiddenHeight: 80,
  controlsHeight: 16,
  controlsGap: 8,
} as const;

export interface RailState {
  /** When pinned the rail stays full-width; otherwise it collapses to a slim bar when idle. */
  pinned: boolean;
  hovered: boolean;
}

const TOP_GAP = 12;

/**
 * Bounds for the floating rail. It stays flush against the right screen edge and hangs
 * from just below the top of the visible work area, mirroring `NotchGeometry` in the
 * native app. The height grows from the compact rail to the hover height when hovered.
 */
export function railBounds(area: WorkArea, state: RailState): Electron.Rectangle {
  const expandedWidth = NOTCH.idleWidth;
  const expanded = state.hovered || state.pinned;
  const width = expanded ? expandedWidth : NOTCH.hiddenWidth;
  const height = expanded ? (state.hovered ? NOTCH.hoverHeight : NOTCH.compactHeight) : NOTCH.hiddenHeight;
  return { x: area.x + area.width - width, y: area.y + TOP_GAP, width, height };
}

/**
 * Bounds for the hover card, which appears to the left of the rail and is vertically
 * centred on the hovered provider's progress ring. The card keeps a pointer notch on its
 * right edge that points back toward the rail.
 */
export function cardBounds(area: WorkArea, providerIndex: number, cardHeight: number): Electron.Rectangle {
  const railX = area.x + area.width - NOTCH.idleWidth;
  const cardX = railX - NOTCH.cardSpacing - NOTCH.cardWidth;
  const providerCenterY = area.y + TOP_GAP + TOP_GAP + providerIndex * (NOTCH.providerItemHeight + NOTCH.providerSpacing) + NOTCH.providerItemHeight / 2;
  const minY = area.y + 8;
  const maxY = area.y + area.height - cardHeight - 8;
  const cardY = Math.min(Math.max(providerCenterY - cardHeight / 2, minY), Math.max(minY, maxY));
  return { x: cardX, y: cardY, width: NOTCH.cardWidth, height: cardHeight };
}

/** Rough card height estimate used before the renderer reports its measured height. */
export function estimateCardHeight(providerWindowCount: number): number {
  return Math.min(Math.max(150 + providerWindowCount * 64, 150), 520);
}
