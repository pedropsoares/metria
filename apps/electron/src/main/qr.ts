/**
 * Minimal QR Code encoder (byte mode, error-correction level M), the same code the
 * macOS app gets from Core Image's `CIQRCodeGenerator`. Kept in-tree rather than pulled
 * from npm for the same reason the PWA vendors its decoder: the pairing link never
 * leaves the machine, so the encoder should not add a dependency to reach it.
 *
 * Follows the ISO/IEC 18004 encoding steps; `src/test/qr.test.ts` decodes what it draws
 * with the PWA's vendored jsQR to prove the output is a readable QR code.
 */

// Indexed by version 1-40 (index 0 unused), for error-correction level M.
const ECC_CODEWORDS_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
const ECC_BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];
const FORMAT_BITS_M = 0;
const MIN_VERSION = 1;
const MAX_VERSION = 40;
const PENALTY_N1 = 3, PENALTY_N2 = 3, PENALTY_N3 = 40, PENALTY_N4 = 10;

export interface QRCode { size: number; modules: boolean[][]; }

/** Encodes `text` as UTF-8 in a single byte-mode segment, at the smallest version that fits. */
export function encodeQRCode(text: string): QRCode {
  const data = Buffer.from(text, "utf8");
  const version = smallestVersion(data.length);
  const bits: number[] = [];
  appendBits(bits, 0b0100, 4);
  appendBits(bits, data.length, characterCountBits(version));
  for (const byte of data) appendBits(bits, byte, 8);

  const capacityBits = dataCodewords(version) * 8;
  appendBits(bits, 0, Math.min(4, capacityBits - bits.length));
  appendBits(bits, 0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < capacityBits; pad ^= 0xec ^ 0x11) appendBits(bits, pad, 8);

  const codewords = Buffer.alloc(bits.length / 8);
  bits.forEach((bit, index) => { codewords[index >>> 3]! |= bit << (7 - (index & 7)); });
  return draw(version, addEccAndInterleave(codewords, version));
}

/** Renders the code as a standalone SVG document, one module per unit of the view box. */
export function qrCodeSVG(text: string, border = 2): string {
  const { size, modules } = encodeQRCode(text);
  const path: string[] = [];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) if (modules[y]![x]) path.push(`M${x + border} ${y + border}h1v1h-1z`);
  }
  const side = size + border * 2;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${side} ${side}" shape-rendering="crispEdges">`
    + `<rect width="${side}" height="${side}" fill="#ffffff"/>`
    + `<path d="${path.join("")}" fill="#000000"/></svg>`;
}

/** The SVG as a `data:` URL, ready for an `<img src>` in the sandboxed renderer. */
export function qrCodeDataURL(text: string, border = 2): string {
  return `data:image/svg+xml;base64,${Buffer.from(qrCodeSVG(text, border), "utf8").toString("base64")}`;
}

function characterCountBits(version: number): number { return version <= 9 ? 8 : 16; }

function smallestVersion(byteCount: number): number {
  for (let version = MIN_VERSION; version <= MAX_VERSION; version++) {
    if (dataCodewords(version) * 8 >= 4 + characterCountBits(version) + byteCount * 8) return version;
  }
  throw new Error("The pairing link is too long to encode as a QR code.");
}

function rawDataModules(version: number): number {
  let result = (16 * version + 128) * version + 64;
  if (version >= 2) {
    const alignCount = Math.floor(version / 7) + 2;
    result -= (25 * alignCount - 10) * alignCount - 55;
    if (version >= 7) result -= 36;
  }
  return result;
}

function dataCodewords(version: number): number {
  return Math.floor(rawDataModules(version) / 8) - ECC_CODEWORDS_PER_BLOCK[version]! * ECC_BLOCKS[version]!;
}

function appendBits(bits: number[], value: number, length: number): void {
  for (let shift = length - 1; shift >= 0; shift--) bits.push((value >>> shift) & 1);
}

/** Splits the data into blocks, appends each block's Reed-Solomon codewords, and
 * interleaves the blocks the way the standard requires. */
function addEccAndInterleave(data: Buffer, version: number): Buffer {
  const blockCount = ECC_BLOCKS[version]!;
  const eccLength = ECC_CODEWORDS_PER_BLOCK[version]!;
  const rawCodewords = Math.floor(rawDataModules(version) / 8);
  const shortBlockCount = blockCount - (rawCodewords % blockCount);
  const shortBlockLength = Math.floor(rawCodewords / blockCount);
  const divisor = reedSolomonDivisor(eccLength);

  const blocks: number[][] = [];
  for (let index = 0, offset = 0; index < blockCount; index++) {
    const length = shortBlockLength - eccLength + (index < shortBlockCount ? 0 : 1);
    const chunk = data.subarray(offset, offset + length);
    offset += length;
    const block = [...chunk];
    // Short blocks carry a placeholder so every block has the same length while
    // interleaving; the placeholder is skipped when the result is assembled.
    if (index < shortBlockCount) block.push(0);
    blocks.push([...block, ...reedSolomonRemainder(chunk, divisor)]);
  }

  const result: number[] = [];
  for (let index = 0; index < blocks[0]!.length; index++) {
    blocks.forEach((block, blockIndex) => {
      if (index !== shortBlockLength - eccLength || blockIndex >= shortBlockCount) result.push(block[index]!);
    });
  }
  return Buffer.from(result);
}

function reedSolomonDivisor(degree: number): Uint8Array {
  const result = new Uint8Array(degree);
  result[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      result[j] = multiply(result[j]!, root);
      if (j + 1 < degree) result[j]! ^= result[j + 1]!;
    }
    root = multiply(root, 0x02);
  }
  return result;
}

function reedSolomonRemainder(data: Uint8Array, divisor: Uint8Array): Uint8Array {
  const result = new Uint8Array(divisor.length);
  for (const byte of data) {
    const factor = byte ^ result[0]!;
    result.copyWithin(0, 1);
    result[result.length - 1] = 0;
    divisor.forEach((coefficient, index) => { result[index]! ^= multiply(coefficient, factor); });
  }
  return result;
}

/** Multiplication in GF(2^8) modulo the QR Code field polynomial x^8 + x^4 + x^3 + x^2 + 1. */
function multiply(x: number, y: number): number {
  let result = 0;
  for (let shift = 7; shift >= 0; shift--) {
    result = (result << 1) ^ ((result >>> 7) * 0x11d);
    result ^= ((y >>> shift) & 1) * x;
  }
  return result & 0xff;
}

function draw(version: number, codewords: Buffer): QRCode {
  const size = version * 4 + 17;
  const modules: boolean[][] = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const isFunction: boolean[][] = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const setFunction = (x: number, y: number, dark: boolean): void => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    modules[y]![x] = dark;
    isFunction[y]![x] = true;
  };

  for (let i = 0; i < size; i++) { setFunction(6, i, i % 2 === 0); setFunction(i, 6, i % 2 === 0); }
  for (const [centerX, centerY] of [[3, 3], [size - 4, 3], [3, size - 4]] as const) {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const distance = Math.max(Math.abs(dx), Math.abs(dy));
        setFunction(centerX + dx, centerY + dy, distance !== 2 && distance !== 4);
      }
    }
  }
  const alignment = alignmentPatternPositions(version);
  alignment.forEach((centerY, row) => {
    alignment.forEach((centerX, column) => {
      const isFinderCorner = (row === 0 && column === 0)
        || (row === 0 && column === alignment.length - 1)
        || (row === alignment.length - 1 && column === 0);
      if (isFinderCorner) return;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) setFunction(centerX + dx, centerY + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
      }
    });
  });
  if (version >= 7) drawVersion(version, size, setFunction);
  // Reserve the format-information modules with a placeholder mask before any codeword
  // is placed; the real format bits are drawn once the mask is chosen.
  drawFormatBits(0, size, setFunction);

  // Codewords fill every non-function module in a two-column zigzag from the
  // bottom-right corner, skipping the vertical timing column.
  let bitIndex = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vertical = 0; vertical < size; vertical++) {
      for (let column = 0; column < 2; column++) {
        const x = right - column;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vertical : vertical;
        if (isFunction[y]![x] || bitIndex >= codewords.length * 8) continue;
        modules[y]![x] = ((codewords[bitIndex >>> 3]! >>> (7 - (bitIndex & 7))) & 1) === 1;
        bitIndex++;
      }
    }
  }

  let bestMask = 0;
  let bestPenalty = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    applyMask(modules, isFunction, mask);
    drawFormatBits(mask, size, setFunction);
    const penalty = penaltyScore(modules, size);
    if (penalty < bestPenalty) { bestPenalty = penalty; bestMask = mask; }
    applyMask(modules, isFunction, mask);
  }
  applyMask(modules, isFunction, bestMask);
  drawFormatBits(bestMask, size, setFunction);
  return { size, modules };
}

function alignmentPatternPositions(version: number): number[] {
  if (version === 1) return [];
  const count = Math.floor(version / 7) + 2;
  const step = version === 32 ? 26 : Math.ceil((version * 4 + 4) / (count * 2 - 2)) * 2;
  const result = [6];
  for (let position = version * 4 + 10; result.length < count; position -= step) result.splice(1, 0, position);
  return result;
}

function drawFormatBits(mask: number, size: number, setFunction: (x: number, y: number, dark: boolean) => void): void {
  const data = (FORMAT_BITS_M << 3) | mask;
  let remainder = data;
  for (let i = 0; i < 10; i++) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537);
  const bits = ((data << 10) | remainder) ^ 0x5412;
  const bit = (index: number): boolean => ((bits >>> index) & 1) === 1;

  for (let i = 0; i <= 5; i++) setFunction(8, i, bit(i));
  setFunction(8, 7, bit(6));
  setFunction(8, 8, bit(7));
  setFunction(7, 8, bit(8));
  for (let i = 9; i < 15; i++) setFunction(14 - i, 8, bit(i));
  for (let i = 0; i < 8; i++) setFunction(size - 1 - i, 8, bit(i));
  for (let i = 8; i < 15; i++) setFunction(8, size - 15 + i, bit(i));
  setFunction(8, size - 8, true);
}

function drawVersion(version: number, size: number, setFunction: (x: number, y: number, dark: boolean) => void): void {
  let remainder = version;
  for (let i = 0; i < 12; i++) remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1f25);
  const bits = (version << 12) | remainder;
  for (let i = 0; i < 18; i++) {
    const dark = ((bits >>> i) & 1) === 1;
    const a = size - 11 + (i % 3);
    const b = Math.floor(i / 3);
    setFunction(a, b, dark);
    setFunction(b, a, dark);
  }
}

function applyMask(modules: boolean[][], isFunction: boolean[][], mask: number): void {
  for (let y = 0; y < modules.length; y++) {
    for (let x = 0; x < modules.length; x++) {
      if (isFunction[y]![x]) continue;
      if (maskCondition(mask, x, y)) modules[y]![x] = !modules[y]![x];
    }
  }
}

function maskCondition(mask: number, x: number, y: number): boolean {
  switch (mask) {
    case 0: return (x + y) % 2 === 0;
    case 1: return y % 2 === 0;
    case 2: return x % 3 === 0;
    case 3: return (x + y) % 3 === 0;
    case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
    case 5: return ((x * y) % 2) + ((x * y) % 3) === 0;
    case 6: return (((x * y) % 2) + ((x * y) % 3)) % 2 === 0;
    default: return (((x + y) % 2) + ((x * y) % 3)) % 2 === 0;
  }
}

/** The standard's mask penalty: runs of five or more, 2x2 blocks, finder-like patterns,
 * and an unbalanced dark/light ratio. The lowest-scoring mask is the one drawn. */
function penaltyScore(modules: boolean[][], size: number): number {
  let result = 0;
  let darkCount = 0;

  for (const axis of ["row", "column"] as const) {
    for (let major = 0; major < size; major++) {
      let runColor = false;
      let runLength = 0;
      const history = [0, 0, 0, 0, 0, 0, 0];
      for (let minor = 0; minor < size; minor++) {
        const dark = axis === "row" ? modules[major]![minor]! : modules[minor]![major]!;
        if (axis === "row" && dark) darkCount++;
        if (dark === runColor) {
          runLength++;
          if (runLength === 5) result += PENALTY_N1;
          else if (runLength > 5) result++;
        } else {
          addRunToHistory(runLength, history, size);
          if (!runColor) result += finderPenaltyCount(history) * PENALTY_N3;
          runColor = dark;
          runLength = 1;
        }
      }
      result += terminalFinderPenalty(runColor, runLength, history, size) * PENALTY_N3;
    }
  }

  for (let y = 0; y < size - 1; y++) {
    for (let x = 0; x < size - 1; x++) {
      const color = modules[y]![x]!;
      if (color === modules[y]![x + 1] && color === modules[y + 1]![x] && color === modules[y + 1]![x + 1]) result += PENALTY_N2;
    }
  }

  const total = size * size;
  const deviation = Math.ceil(Math.abs(darkCount * 20 - total * 10) / total) - 1;
  return result + deviation * PENALTY_N4;
}

/** Pushes one run onto the seven-run history, padding the very first run with the light
 * border outside the symbol so an edge finder pattern still scores. */
function addRunToHistory(runLength: number, history: number[], size: number): void {
  if (history[0] === 0) runLength += size;
  history.pop();
  history.unshift(runLength);
}

/** Counts 1:1:3:1:1 finder-like patterns bounded by four light modules on either side. */
function finderPenaltyCount(history: number[]): number {
  const n = history[1]!;
  const core = n > 0 && history[2] === n && history[3] === n * 3 && history[4] === n && history[5] === n;
  return (core && history[0]! >= n * 4 && history[6]! >= n ? 1 : 0) + (core && history[6]! >= n * 4 && history[0]! >= n ? 1 : 0);
}

function terminalFinderPenalty(runColor: boolean, runLength: number, history: number[], size: number): number {
  if (runColor) {
    addRunToHistory(runLength, history, size);
    runLength = 0;
  }
  addRunToHistory(runLength + size, history, size);
  return finderPenaltyCount(history);
}
