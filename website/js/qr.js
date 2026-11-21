// A small QR code encoder: version 3, error correction L, byte mode, mask 0. Up to 53 bytes, enough for a link.
// Follows ISO/IEC 18004; the result scans with a phone camera.

const SIZE = 29;
const DATA_CODEWORDS = 55;
const EC_CODEWORDS = 15;

function gfMul(x, y) {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z & 0xff;
}

function rsDivisor(degree) {
  const result = new Array(degree).fill(0);
  result[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < result.length; j++) {
      result[j] = gfMul(result[j], root);
      if (j + 1 < result.length) result[j] ^= result[j + 1];
    }
    root = gfMul(root, 0x02);
  }
  return result;
}

function rsRemainder(data, divisor) {
  const result = divisor.map(() => 0);
  for (const b of data) {
    const factor = b ^ result.shift();
    result.push(0);
    divisor.forEach((coef, i) => { result[i] ^= gfMul(coef, factor); });
  }
  return result;
}

export function encodeQR(text) {
  const bytes = Array.from(new TextEncoder().encode(text));
  if (bytes.length > 53) throw new Error('Too long for a version 3 QR code');

  // Bit stream: mode 0100, 8-bit count, data, terminator, padding.
  const bits = [];
  const push = (val, len) => { for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
  push(0b0100, 4);
  push(bytes.length, 8);
  bytes.forEach((b) => push(b, 8));
  push(0, Math.min(4, DATA_CODEWORDS * 8 - bits.length));
  while (bits.length % 8) bits.push(0);
  const data = [];
  for (let i = 0; i < bits.length; i += 8) data.push(parseInt(bits.slice(i, i + 8).join(''), 2));
  for (let pad = 0xec; data.length < DATA_CODEWORDS; pad ^= 0xec ^ 0x11) data.push(pad);
  const codewords = data.concat(rsRemainder(data, rsDivisor(EC_CODEWORDS)));

  const modules = Array.from({ length: SIZE }, () => new Array(SIZE).fill(false));
  const isFunction = Array.from({ length: SIZE }, () => new Array(SIZE).fill(false));
  const set = (x, y, dark) => { modules[y][x] = dark; isFunction[y][x] = true; };

  // Timing patterns.
  for (let i = 0; i < SIZE; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
  // Finder patterns with separators.
  const finder = (cx, cy) => {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx;
        const y = cy + dy;
        if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) continue;
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        set(x, y, d !== 2 && d !== 4);
      }
    }
  };
  finder(3, 3);
  finder(SIZE - 4, 3);
  finder(3, SIZE - 4);
  // Alignment pattern (version 3: centre 22,22).
  for (let dy = -2; dy <= 2; dy++) {
    for (let dx = -2; dx <= 2; dx++) set(22 + dx, 22 + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }

  // Format bits: level L (01), mask 0.
  const fmtData = (1 << 3) | 0;
  let rem = fmtData;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  const fmt = ((fmtData << 10) | rem) ^ 0x5412;
  const bit = (i) => ((fmt >>> i) & 1) === 1;
  for (let i = 0; i <= 5; i++) set(8, i, bit(i));
  set(8, 7, bit(6));
  set(8, 8, bit(7));
  set(7, 8, bit(8));
  for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
  for (let i = 0; i < 8; i++) set(SIZE - 1 - i, 8, bit(i));
  for (let i = 8; i < 15; i++) set(8, SIZE - 15 + i, bit(i));
  set(8, SIZE - 8, true); // the dark module

  // Data, in the zigzag order, with mask 0 ((x + y) % 2 === 0) applied.
  let i = 0;
  for (let right = SIZE - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < SIZE; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? SIZE - 1 - vert : vert;
        if (isFunction[y][x]) continue;
        let dark = false;
        if (i < codewords.length * 8) { dark = ((codewords[i >>> 3] >>> (7 - (i & 7))) & 1) === 1; i++; }
        if ((x + y) % 2 === 0) dark = !dark;
        modules[y][x] = dark;
      }
    }
  }
  return modules;
}

/** Draws the code with a 4-module quiet zone into `g` at (x, y), `size` pixels wide. */
export function drawQR(g, modules, x, y, size, dark = '#111', light = '#fff') {
  const n = modules.length + 8;
  const m = size / n;
  g.fillStyle = light;
  g.fillRect(x, y, size, size);
  g.fillStyle = dark;
  modules.forEach((row, r) => row.forEach((on, c) => {
    if (on) g.fillRect(Math.floor(x + (c + 4) * m), Math.floor(y + (r + 4) * m), Math.ceil(m), Math.ceil(m));
  }));
}
