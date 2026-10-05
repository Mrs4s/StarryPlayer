// Cipher primitives behind the eapi envelope.

export const EAPI_KEY = 'e82ckenh8dichen8';
/** AES key of the nginx `cache_key` (`cacheKey`). */
export const CACHE_KEY_SECRET = ')(13daqP@ssw0rd~';
const ANONYMOUS_XOR_KEY = '3go8&$8*3*3h0k(2)2';

export const md5Hex = (input: string): string => starry.crypto.md5(input, 'hex');

/** `md5("nobody" + url + "use" + json + "md5forencrypt")`. */
export const eapiDigest = (url: string, json: string) => md5Hex(`nobody${url}use${json}md5forencrypt`);

/** AES-ECB with PKCS#7 padding; a string key is its UTF-8 bytes. */
export function aesECBEncrypt(data: string | Uint8Array, key: string | Uint8Array): Uint8Array {
  return starry.crypto.aes.encrypt({ mode: 'ecb', key, data });
}

export function aesECBDecrypt(data: Uint8Array, key: string | Uint8Array): Uint8Array {
  return starry.crypto.aes.decrypt({ mode: 'ecb', key, data });
}

/** eapi body: `params = HEX(AES-ECB(url + "-36cd479b6b5-" + json + "-36cd479b6b5-" + digest))`. */
export function eapiParams(url: string, json: string): string {
  const text = `${url}-36cd479b6b5-${json}-36cd479b6b5-${eapiDigest(url, json)}`;
  return starry.encoding.hex.encode(aesECBEncrypt(text, EAPI_KEY)).toUpperCase();
}

/** nginx `cache_key`: base64(AES-128-ECB(sorted `k=v&…` query)). */
export const cacheKey = (query: string) => starry.encoding.base64.encode(aesECBEncrypt(query, CACHE_KEY_SECRET));

// Ciphertext can start with `{` or `[`; only accept plaintext after JSON parsing succeeds.
export function eapiDecryptResponse(data: Uint8Array): Uint8Array {
  if (isJSON(data)) return data;
  if (data.length === 0 || data.length % 16 !== 0) throw starry.error('invalidResponse', `网易云的加密响应长度不对（${data.length} 字节）`);
  return gunzipIfNeeded(aesECBDecrypt(data, EAPI_KEY));
}

function isJSON(data: Uint8Array): boolean {
  const first = data.find((byte) => byte !== 0x20 && byte !== 0x0a && byte !== 0x0d && byte !== 0x09);
  if (first !== 0x7b && first !== 0x5b) return false;
  try {
    JSON.parse(starry.encoding.utf8.decode(data));
    return true;
  } catch {
    return false;
  }
}

export function gunzipIfNeeded(data: Uint8Array): Uint8Array {
  return data.length > 2 && data[0] === 0x1f && data[1] === 0x8b ? starry.zlib.inflate(data) : data;
}

export function anonymousUsername(deviceID: string): string {
  const id = starry.encoding.utf8.encode(deviceID);
  const xored = new Uint8Array(id.length);
  for (let i = 0; i < id.length; i++) xored[i] = id[i] ^ ANONYMOUS_XOR_KEY.charCodeAt(i % ANONYMOUS_XOR_KEY.length);
  // The XORed bytes are taken as characters (Latin-1), then hashed as UTF-8.
  let text = '';
  for (const byte of xored) text += String.fromCharCode(byte);
  const digest = starry.crypto.md5(text, 'base64');
  return starry.encoding.base64.encode(`${deviceID} ${digest}`);
}
