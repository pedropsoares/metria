import test from "node:test";
import assert from "node:assert/strict";
import { pairingLink } from "../main/pairing-link";

const SECRET = "ABEiM0RVZneImaq7zN3u_w";

// The iOS client parses the fragment by assigning it to `URLComponents.query`, which does
// not percent-decode, so an escaped value reaches the phone escaped: it would look for a
// relay literally named "https%3A%2F%2Fntfy.sh". The native app leaves ":" and "/" alone
// (`.urlQueryAllowed`), and this must match it exactly.
test("builds the link the native app builds, with ':' and '/' left literal", () => {
  assert.equal(
    pairingLink(SECRET, "https://metria-pwa.example.workers.dev", "https://ntfy.sh", "http://192.168.1.134:8973"),
    `https://metria-pwa.example.workers.dev/#s=${SECRET}&server=https://ntfy.sh&local=http://192.168.1.134:8973`
  );
});

test("omits the local address when the machine has none", () => {
  assert.equal(pairingLink(SECRET, "https://metria-pwa.example.workers.dev", "https://ntfy.sh", null),
    `https://metria-pwa.example.workers.dev/#s=${SECRET}&server=https://ntfy.sh`);
});

test("escapes what would otherwise split the fragment", () => {
  const link = pairingLink(SECRET, "http://192.168.1.134:8973", "https://relay.example.com/a path", null);
  assert.equal(link, `http://192.168.1.134:8973/#s=${SECRET}&server=https://relay.example.com/a%20path`);
});

test("round-trips through the PWA's parser", () => {
  const link = pairingLink(SECRET, "https://metria-pwa.example.workers.dev", "https://ntfy.example.com/relay", "http://10.0.0.7:8973");
  const params = new URLSearchParams(link.split("#")[1]);
  assert.equal(params.get("s"), SECRET);
  assert.equal(params.get("server"), "https://ntfy.example.com/relay");
  assert.equal(params.get("local"), "http://10.0.0.7:8973");
});
