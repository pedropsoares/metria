import type { MetriaApi } from "./types";

declare global {
  interface Window { metria: MetriaApi; }
}

export {};
