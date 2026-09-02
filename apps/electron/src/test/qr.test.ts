import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { encodeQRCode, qrCodeDataURL, qrCodeSVG } from "../main/qr";

/** The decoder the PWA already vendors, used here to read back what the encoder draws. */
const jsQR = require(join(__dirname, "..", "..", "..", "pwa", "public", "jsQR.js")) as
  (data: Uint8ClampedArray, width: number, height: number) => { data: string } | null;

/** Rasterises the code with a quiet zone, the way a phone camera would see it. */
function decode(text: string, scale = 4, border = 4): string | null {
  const { size, modules } = encodeQRCode(text);
  const side = (size + border * 2) * scale;
  const pixels = new Uint8ClampedArray(side * side * 4).fill(255);
  for (let y = 0; y < side; y++) {
    for (let x = 0; x < side; x++) {
      const moduleX = Math.floor(x / scale) - border;
      const moduleY = Math.floor(y / scale) - border;
      if (moduleX < 0 || moduleY < 0 || moduleX >= size || moduleY >= size || !modules[moduleY]![moduleX]) continue;
      const offset = (y * side + x) * 4;
      pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = 0;
    }
  }
  return jsQR(pixels, side, side)?.data ?? null;
}

test("encodes a pairing link a scanner can read back", () => {
  const link = "http://192.168.1.23:8973/#s=ABEiM0RVZneImaq7zN3u_w&server=https%3A%2F%2Fntfy.sh&local=http%3A%2F%2F192.168.1.23%3A8973";
  assert.equal(decode(link), link);
});

test("grows to fit longer links and non-ASCII text", () => {
  const hosted = `https://metria-pwa.example.workers.dev/#s=ABEiM0RVZneImaq7zN3u_w&server=${encodeURIComponent("https://ntfy.example.com/a/very/long/relay/path")}&local=${encodeURIComponent("http://192.168.100.200:65535")}`;
  assert.equal(decode(hosted), hosted);
  assert.equal(decode("ação · café ✅"), "ação · café ✅");
  assert.equal(decode("x".repeat(1200)), "x".repeat(1200));
});

test("uses the smallest version that fits, and refuses text that fits in none", () => {
  assert.equal(encodeQRCode("A").size, 21, "version 1");
  assert.equal(encodeQRCode("x".repeat(500)).size, 85, "version 17");
  assert.throws(() => encodeQRCode("x".repeat(3000)), /too long/);
});

test("renders an SVG data URL the sandboxed renderer can display", () => {
  const svg = qrCodeSVG("metria", 2);
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" viewBox="0 0 25 25"/);
  const dataUrl = qrCodeDataURL("metria", 2);
  assert.ok(dataUrl.startsWith("data:image/svg+xml;base64,"));
  assert.equal(Buffer.from(dataUrl.slice("data:image/svg+xml;base64,".length), "base64").toString("utf8"), svg);
});
