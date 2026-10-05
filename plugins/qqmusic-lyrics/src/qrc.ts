// QQ DES differs from FIPS: little-endian bytes within words, two modified S-box
// entries, and a one-bit-shifted PC-2 D half. The host's standard DES is incompatible.

const KEY = starry.encoding.utf8.encode('!@#)(*$%123ZXC!@!@#)(NHL');

const INITIAL: number[] = (() => {
  const table: number[] = [];
  for (const start of [57, 59, 61, 63, 56, 58, 60, 62]) for (let step = 0; step < 8; step++) table.push(start - step * 8);
  return table;
})();

const FINAL: number[] = (() => {
  const inverse = new Array<number>(64).fill(0);
  INITIAL.forEach((source, index) => (inverse[source] = index));
  return inverse;
})();

const EXPANSION = [
  31, 0, 1, 2, 3, 4, 3, 4, 5, 6, 7, 8, 7, 8, 9, 10, 11, 12, 11, 12, 13, 14, 15, 16,
  15, 16, 17, 18, 19, 20, 19, 20, 21, 22, 23, 24, 23, 24, 25, 26, 27, 28, 27, 28, 29, 30, 31, 0,
];

const P_BOX = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24];

const PC1 = [
  56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
  62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
];

/** Standard PC-2 over the 57-bit register (C, D, 0): C taps as they are, D taps one bit late. */
const PC2 = [
  13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
  40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
].map((index) => (index < 28 ? index : index + 1));

const ROTATIONS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

const S_BOXES: number[][] = (() => {
  const boxes = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
  ];
  boxes[1][1 * 16 + 7] = 15;
  boxes[3][3 * 16 + 5] = 10;
  return boxes;
})();

/** Byte `n` of the logical block lives at `(n / 4) * 4 + 3 - n % 4`. */
const swapped = (n: number) => (n >> 2) * 4 + 3 - (n & 3);

function loadBits(bytes: Uint8Array, offset: number): Uint8Array {
  const bits = new Uint8Array(64);
  for (let n = 0; n < 8; n++) {
    const byte = bytes[offset + swapped(n)];
    for (let b = 0; b < 8; b++) bits[n * 8 + b] = (byte >> (7 - b)) & 1;
  }
  return bits;
}

function storeBits(bits: Uint8Array, bytes: Uint8Array, offset: number): void {
  for (let n = 0; n < 8; n++) {
    let byte = 0;
    for (let b = 0; b < 8; b++) byte = (byte << 1) | bits[n * 8 + b];
    bytes[offset + swapped(n)] = byte;
  }
}

function permute(bits: Uint8Array, table: number[]): Uint8Array {
  const out = new Uint8Array(table.length);
  for (let i = 0; i < table.length; i++) out[i] = bits[table[i]];
  return out;
}

function subkeys(key: Uint8Array, decrypt: boolean): Uint8Array[] {
  const cd = permute(loadBits(key, 0), PC1);
  let c = cd.slice(0, 28);
  let d = cd.slice(28, 56);
  const keys: Uint8Array[] = new Array(16);
  for (let round = 0; round < 16; round++) {
    const shift = ROTATIONS[round];
    c = Uint8Array.from({ length: 28 }, (_, i) => c[(i + shift) % 28]);
    d = Uint8Array.from({ length: 28 }, (_, i) => d[(i + shift) % 28]);
    const register = new Uint8Array(57);
    register.set(c, 0);
    register.set(d, 28);
    keys[decrypt ? 15 - round : round] = permute(register, PC2);
  }
  return keys;
}

function feistel(half: Uint8Array, key: Uint8Array): Uint8Array {
  const expanded = new Uint8Array(48);
  for (let i = 0; i < 48; i++) expanded[i] = half[EXPANSION[i]] ^ key[i];
  const substituted = new Uint8Array(32);
  for (let box = 0; box < 8; box++) {
    const b = box * 6;
    const row = (expanded[b] << 1) | expanded[b + 5];
    const column = (expanded[b + 1] << 3) | (expanded[b + 2] << 2) | (expanded[b + 3] << 1) | expanded[b + 4];
    const value = S_BOXES[box][row * 16 + column];
    for (let bit = 0; bit < 4; bit++) substituted[box * 4 + bit] = (value >> (3 - bit)) & 1;
  }
  return permute(substituted, P_BOX);
}

function des(block: Uint8Array, keys: Uint8Array[]): Uint8Array {
  const permuted = permute(block, INITIAL);
  let left = permuted.slice(0, 32);
  let right = permuted.slice(32, 64);
  for (let round = 0; round < 16; round++) {
    const f = feistel(right, keys[round]);
    const next = new Uint8Array(32);
    for (let i = 0; i < 32; i++) next[i] = left[i] ^ f[i];
    if (round === 15) {
      left = next;
    } else {
      left = right;
      right = next;
    }
  }
  const joined = new Uint8Array(64);
  joined.set(left, 0);
  joined.set(right, 32);
  return permute(joined, FINAL);
}

let decryption: Uint8Array[][] | undefined;
let encryption: Uint8Array[][] | undefined;

function run(data: Uint8Array, stages: Uint8Array[][]): Uint8Array {
  if (data.length % 8 !== 0) throw new Error('QRC: bad length');
  const output = new Uint8Array(data.length);
  for (let offset = 0; offset < data.length; offset += 8) {
    let block = loadBits(data, offset);
    for (const stage of stages) block = des(block, stage);
    storeBits(block, output, offset);
  }
  return output;
}

/** EDE decryption: D(k3) → E(k2) → D(k1). */
export function qrcDecrypt(data: Uint8Array): Uint8Array {
  decryption ??= [subkeys(KEY.subarray(16, 24), true), subkeys(KEY.subarray(8, 16), false), subkeys(KEY.subarray(0, 8), true)];
  return run(data, decryption);
}

/** The inverse, E(k1) → D(k2) → E(k3), for tests to make the gateway's payloads. */
export function qrcEncrypt(data: Uint8Array): Uint8Array {
  encryption ??= [subkeys(KEY.subarray(0, 8), false), subkeys(KEY.subarray(8, 16), true), subkeys(KEY.subarray(16, 24), false)];
  return run(data, encryption);
}

export function qrcText(hexText: string | undefined): string | null {
  if (!hexText) return null;
  try {
    const bytes = starry.encoding.hex.decode(hexText);
    const text = starry.zlib.inflate(qrcDecrypt(bytes), 'utf8') as string;
    return text.trim() ? text : null;
  } catch {
    return null;
  }
}
