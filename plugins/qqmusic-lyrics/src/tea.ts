// QQ TEA uses 16 rounds and custom chaining: x[i] = p[i] ^ c[i−1],
// c[i] = TEA(x[i]) ^ x[i−1]. Framing includes random padding and seven trailing zero bytes.

const DELTA = 0x9e3779b9;

function words(key: Uint8Array): number[] {
  const k: number[] = [];
  for (let i = 0; i < 4; i++) k.push(((key[i * 4] << 24) | (key[i * 4 + 1] << 16) | (key[i * 4 + 2] << 8) | key[i * 4 + 3]) >>> 0);
  return k;
}

function encryptBlock(y: number, z: number, k: number[]): [number, number] {
  let sum = 0;
  for (let i = 0; i < 16; i++) {
    sum = (sum + DELTA) >>> 0;
    y = (y + (((((z << 4) + k[0]) ^ (z + sum) ^ ((z >>> 5) + k[1])) >>> 0))) >>> 0;
    z = (z + (((((y << 4) + k[2]) ^ (y + sum) ^ ((y >>> 5) + k[3])) >>> 0))) >>> 0;
  }
  return [y, z];
}

function decryptBlock(y: number, z: number, k: number[]): [number, number] {
  let sum = (DELTA * 16) >>> 0;
  for (let i = 0; i < 16; i++) {
    z = (z - (((((y << 4) + k[2]) ^ (y + sum) ^ ((y >>> 5) + k[3])) >>> 0))) >>> 0;
    y = (y - (((((z << 4) + k[0]) ^ (z + sum) ^ ((z >>> 5) + k[1])) >>> 0))) >>> 0;
    sum = (sum - DELTA) >>> 0;
  }
  return [y, z];
}

function load(bytes: Uint8Array, offset: number): [number, number] {
  const word = (at: number) => ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0;
  return [word(offset), word(offset + 4)];
}

function store(high: number, low: number, bytes: Uint8Array, offset: number): void {
  for (let i = 0; i < 4; i++) {
    bytes[offset + i] = (high >>> (24 - i * 8)) & 0xff;
    bytes[offset + 4 + i] = (low >>> (24 - i * 8)) & 0xff;
  }
}

/** `random` makes the padding (tests pass a fixed one). */
export function teaEncrypt(data: Uint8Array, key: Uint8Array, random: (count: number) => Uint8Array = (count) => starry.crypto.randomBytes(count)): Uint8Array {
  const k = words(key);
  const pad = (8 - ((data.length + 10) % 8)) % 8;
  const noise = random(pad + 3);
  const plain = new Uint8Array(1 + pad + 2 + data.length + 7);
  plain[0] = (noise[0] & 0xf8) | pad;
  for (let i = 1; i < pad + 3; i++) plain[i] = noise[i];
  plain.set(data, pad + 3);

  const out = new Uint8Array(plain.length);
  let previousPlain: [number, number] = [0, 0];
  let previousCipher: [number, number] = [0, 0];
  for (let offset = 0; offset < plain.length; offset += 8) {
    const [ph, pl] = load(plain, offset);
    const x: [number, number] = [(ph ^ previousCipher[0]) >>> 0, (pl ^ previousCipher[1]) >>> 0];
    const [eh, el] = encryptBlock(x[0], x[1], k);
    const c: [number, number] = [(eh ^ previousPlain[0]) >>> 0, (el ^ previousPlain[1]) >>> 0];
    store(c[0], c[1], out, offset);
    previousPlain = x;
    previousCipher = c;
  }
  return out;
}

/** Throws when the length or the padding is wrong (a wrong key). */
export function teaDecrypt(data: Uint8Array, key: Uint8Array): Uint8Array {
  if (data.length < 16 || data.length % 8 !== 0) throw new Error('TEA: bad length');
  const k = words(key);
  const out = new Uint8Array(data.length);
  let previousPlain: [number, number] = [0, 0];
  let previousCipher: [number, number] = [0, 0];
  for (let offset = 0; offset < data.length; offset += 8) {
    const c = load(data, offset);
    const x = decryptBlock((c[0] ^ previousPlain[0]) >>> 0, (c[1] ^ previousPlain[1]) >>> 0, k);
    store((x[0] ^ previousCipher[0]) >>> 0, (x[1] ^ previousCipher[1]) >>> 0, out, offset);
    previousPlain = x;
    previousCipher = c;
  }
  const pad = out[0] & 7;
  const start = 1 + pad + 2;
  const end = out.length - 7;
  if (start > end) throw new Error('TEA: bad padding');
  for (let i = end; i < out.length; i++) if (out[i] !== 0) throw new Error('TEA: bad padding');
  return out.slice(start, end);
}
