import { networkInterfaces } from "node:os";

/**
 * The address a phone on the same Wi-Fi can reach this machine at. Mirrors the macOS
 * app's `LocalNetwork`: prefer the primary wired/wireless interface, never loopback.
 */
export function primaryIPv4Address(): string | null {
  const candidates: { name: string; address: string }[] = [];
  for (const [name, addresses] of Object.entries(networkInterfaces())) {
    for (const entry of addresses ?? []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      candidates.push({ name, address: entry.address });
    }
  }
  const preferred = candidates.find((candidate) => /^(en|eth|wl|Wi-Fi|Ethernet)/i.test(candidate.name));
  return (preferred ?? candidates[0])?.address ?? null;
}
