// NCBL v3 uses little-endian headers and TLVs; each chunk is length, sequence and ciphertext.
// Log lines share an unfinished zstd stream but restart ChaCha20 with the same nonce/counter.
// The user-info TLV uses the RSA-wrapped key; log chunks use the plain key.

import { concat, randomInt } from './util';

export const LOGGER_NAME = 'monitor';
/** Field separator of a log line (`\u0001` between the parts, `\n` at the end). */
export const FIELD_SEPARATOR = '\u0001';

// MARK: ChaCha20 (IETF, RFC 8439)

const rotl = (v: number, n: number) => ((v << n) | (v >>> (32 - n))) >>> 0;

function word(bytes: Uint8Array, index: number): number {
  return (bytes[index] | (bytes[index + 1] << 8) | (bytes[index + 2] << 16) | (bytes[index + 3] << 24)) >>> 0;
}

function chachaBlock(state: Uint32Array): Uint8Array {
  const x = Uint32Array.from(state);
  const quarter = (a: number, b: number, c: number, d: number) => {
    x[a] += x[b]; x[d] = rotl(x[d] ^ x[a], 16);
    x[c] += x[d]; x[b] = rotl(x[b] ^ x[c], 12);
    x[a] += x[b]; x[d] = rotl(x[d] ^ x[a], 8);
    x[c] += x[d]; x[b] = rotl(x[b] ^ x[c], 7);
  };
  for (let i = 0; i < 10; i++) {
    quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15);
    quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14);
  }
  const out = new Uint8Array(64);
  for (let i = 0; i < 16; i++) {
    const v = (x[i] + state[i]) >>> 0;
    out[i * 4] = v & 0xff;
    out[i * 4 + 1] = (v >>> 8) & 0xff;
    out[i * 4 + 2] = (v >>> 16) & 0xff;
    out[i * 4 + 3] = v >>> 24;
  }
  return out;
}

export function chacha20(key: Uint8Array, nonce: Uint8Array, counter: number, data: Uint8Array): Uint8Array {
  if (key.length !== 32 || nonce.length !== 12) throw new RangeError('chacha20 needs a 32-byte key and a 12-byte nonce');
  const state = new Uint32Array(16);
  state[0] = 0x61707865; state[1] = 0x3320646e; state[2] = 0x79622d32; state[3] = 0x6b206574;
  for (let i = 0; i < 8; i++) state[4 + i] = word(key, i * 4);
  state[12] = counter >>> 0;
  for (let i = 0; i < 3; i++) state[13 + i] = word(nonce, i * 4);
  const out = new Uint8Array(data.length);
  for (let offset = 0; offset < data.length; offset += 64) {
    const block = chachaBlock(state);
    const n = Math.min(64, data.length - offset);
    for (let i = 0; i < n; i++) out[offset + i] = data[offset + i] ^ block[i];
    state[12] = (state[12] + 1) >>> 0;
  }
  return out;
}

// MARK: Raw RSA (256-bit modulus)

// The log's 256-bit RSA key is too small for the host crypto API; exponentiate here.
export const KEY_MODULUS = 'fd90bd466ff9bc8a3fec2fbcf263b90d5c564879fa5d7aab89b31c1d5cb4139d';
export const KEY_EXPONENT = 65537n;

/** `RSA_public_encrypt(…, RSA_NO_PADDING)` of a 32-byte block. */
export function wrapKey(block: Uint8Array): Uint8Array {
  if (block.length !== 32) throw new RangeError('wrapKey needs 32 bytes');
  const modulus = BigInt(`0x${KEY_MODULUS}`);
  let base = 0n;
  for (const byte of block) base = (base << 8n) | BigInt(byte);
  base %= modulus;
  let result = 1n;
  let exponent = KEY_EXPONENT;
  while (exponent > 0n) {
    if (exponent & 1n) result = (result * base) % modulus;
    base = (base * base) % modulus;
    exponent >>= 1n;
  }
  const out = new Uint8Array(32);
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(result & 0xffn);
    result >>= 8n;
  }
  return out;
}

/**
 * One zstd frame built from raw (stored) blocks. A log file holds one compressed stream flushed
 * after every line, so the frame is never ended; stored blocks decode identically and need no zstd.
 */
export class RawFrame {
  static readonly magic = Uint8Array.of(0x28, 0xb5, 0x2f, 0xfd);
  /** `Frame_Header_Descriptor` 0 (no content size, no checksum, no dictionary) and a `Window_Descriptor` of exponent 10 → a 1 MiB window. */
  static readonly header = Uint8Array.of(0x00, 10 << 3);
  static readonly maxBlock = 128 * 1024;

  private started = false;

  flush(bytes: Uint8Array): Uint8Array {
    const parts: Uint8Array[] = [];
    if (!this.started) {
      parts.push(RawFrame.magic, RawFrame.header);
      this.started = true;
    }
    for (let offset = 0; offset < bytes.length; offset += RawFrame.maxBlock) {
      const end = Math.min(offset + RawFrame.maxBlock, bytes.length);
      // Block_Header: u24 little-endian of `size << 3` (Last_Block 0, Raw_Block type 0).
      const size = (end - offset) << 3;
      parts.push(Uint8Array.of(size & 0xff, (size >>> 8) & 0xff, (size >>> 16) & 0xff), bytes.subarray(offset, end));
    }
    return concat(parts);
  }

  copy(): RawFrame {
    const copy = new RawFrame();
    copy.started = this.started;
    return copy;
  }
}

export interface LogEvent {
  action: string;
  /** Milliseconds since 1970. */
  time: number;
  data: string;
}

/**
 * A log line, `time \u0001 action \u0001 data \n`; the timestamp is whole seconds (the first ten
 * digits of the millisecond time).
 */
export function eventLine(event: LogEvent): Uint8Array {
  const seconds = Math.floor(event.time / 1000);
  return starry.encoding.utf8.encode(`${seconds}${FIELD_SEPARATOR}${event.action}${FIELD_SEPARATOR}${event.data}\n`);
}

const u16 = (v: number) => Uint8Array.of(v & 0xff, (v >>> 8) & 0xff);
const u32 = (v: number) => Uint8Array.of(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff);

export class EventLogFile {
  static readonly magic = Uint8Array.of(0x4e, 0x43, 0x42, 0x4c);
  static readonly version = 3;
  static readonly baseHeaderLength = 0x46;
  static readonly userInfoTag = 0x4343;
  /** A chunk carries its length in a u16. */
  static readonly maxChunkLength = 0xffff;

  private readonly uuid: Uint8Array;
  private readonly nonce: Uint8Array;
  private readonly counter: number;
  private readonly key: Uint8Array;
  private readonly wrappedKey: Uint8Array;
  private readonly userInfoTLV: Uint8Array;
  private readonly firstSequence: number;
  private lastSequence: number;
  private readonly chunks: Uint8Array[] = [];
  private frame = new RawFrame();
  count = 0;

  // The user-info blob identifies the account. Log sequence numbers must not be reused.
  constructor(userInfo: string, firstSequence = 1) {
    const id = starry.crypto.randomBytes(16);
    id[6] = (id[6] & 0x0f) | 0x40;
    id[8] = (id[8] & 0x3f) | 0x80;
    this.uuid = id;
    this.nonce = id.slice(0, 12);
    this.counter = word(id, 12) >>> 2;

    const material = starry.crypto.randomBytes(32);
    if (material[0] > 0xa2) material[0] = 0xa2;
    this.key = material;
    this.wrappedKey = wrapKey(material);

    const info = chacha20(this.wrappedKey, this.nonce, this.counter, starry.encoding.utf8.encode(userInfo));
    this.userInfoTLV = concat([u16(EventLogFile.userInfoTag), u16(info.length), info]);

    this.firstSequence = firstSequence >>> 0;
    this.lastSequence = this.firstSequence;
  }

  /** Appends one event; false when its line does not fit a chunk. */
  append(event: LogEvent): boolean {
    const next = this.frame.copy();
    const compressed = next.flush(eventLine(event));
    if (compressed.length > EventLogFile.maxChunkLength) return false;
    this.frame = next;
    const sequence = (this.firstSequence + this.count) >>> 0;
    this.chunks.push(u16(compressed.length), u32(sequence), chacha20(this.key, this.nonce, this.counter, compressed));
    this.lastSequence = sequence;
    this.count += 1;
    return true;
  }

  get nextSequence(): number {
    return (this.firstSequence + this.count) >>> 0;
  }

  encoded(): Uint8Array {
    const chunks = concat(this.chunks);
    return concat([
      EventLogFile.magic,
      u32(EventLogFile.version),
      u16(EventLogFile.baseHeaderLength + this.userInfoTLV.length),
      this.uuid,
      this.wrappedKey,
      u32(this.firstSequence),
      u32(this.lastSequence),
      u32(chunks.length),
      this.userInfoTLV,
      chunks,
    ]);
  }

  /** Log files are named `<logger>_<pid>_<rand>_<rand>`; a plugin has no pid, so a made-up one. */
  static fileName(logger = LOGGER_NAME): string {
    const random = () => (randomInt(0x10000) * 0x10000 + randomInt(0x10000)) >>> 0;
    return `${logger}_${10000 + randomInt(90000)}_${random()}_${random()}`;
  }
}
