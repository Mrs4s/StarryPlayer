// Kugou's KRC container: `krc1`, then a zlib stream XOR-ed with a 16-byte key. The download API
// sends it as base64; what it holds is the per-character format the player parses (KRC), with the
// translation and romanization in its `[language:]` tag. (The player reads `.krc` files itself.)

const MAGIC = [0x6b, 0x72, 0x63, 0x31];
const KEY = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69];

/** The KRC text in a base64 download. */
export function krcText(base64: string): string {
  return krcDecrypt(starry.encoding.base64.decode(base64));
}

export function krcDecrypt(data: Uint8Array): string {
  if (data.length <= MAGIC.length || MAGIC.some((byte, index) => data[index] !== byte)) throw starry.error('api', '不是 KRC 歌词');
  const deflated = data.subarray(MAGIC.length).map((byte, index) => byte ^ KEY[index % KEY.length]);
  return starry.zlib.inflate(deflated, 'utf8');
}
