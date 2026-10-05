// The plugin host's JavaScript half: the `starry` object, the web globals JavaScriptCore lacks,
// and the hooks the host calls a plugin through. Runs once in each plugin's context before the
// plugin's own file; its value is the hooks object.
(function (global, native) {
  'use strict';
  delete global.__starryNative;

  function toBytes(data, what) {
    if (typeof data === 'string') return native.utf8Encode(data);
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (Array.isArray(data)) return Uint8Array.from(data);
    throw new TypeError(`${what || 'data'} must be a string or a Uint8Array`);
  }

  const hexDigits = '0123456789abcdef';

  function hexEncode(data) {
    const bytes = toBytes(data);
    let text = '';
    for (let i = 0; i < bytes.length; i++) text += hexDigits[bytes[i] >> 4] + hexDigits[bytes[i] & 15];
    return text;
  }

  function hexDecode(text) {
    const clean = String(text).replace(/\s+/g, '');
    if (clean.length % 2 !== 0 || /[^0-9a-fA-F]/.test(clean)) throw new TypeError('not a hex string');
    const bytes = new Uint8Array(clean.length / 2);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(clean.substr(i * 2, 2), 16);
    return bytes;
  }

  function output(bytes, encoding) {
    switch (encoding) {
      case undefined:
      case null:
      case 'bytes':
        return bytes;
      case 'hex':
        return hexEncode(bytes);
      case 'base64':
        return native.base64Encode(bytes);
      case 'utf8':
      case 'utf-8':
        return native.decodeText(bytes, 'utf-8');
      default:
        throw new TypeError(`unknown output encoding: ${encoding}`);
    }
  }

  const systemConsole = global.console;

  function format(values) {
    return values
      .map((value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value);
        try {
          const text = JSON.stringify(value, (key, item) =>
            item instanceof Uint8Array ? `Uint8Array(${item.length})` : typeof item === 'bigint' ? `${item}n` : item,
          );
          return text === undefined ? String(value) : text;
        } catch (error) {
          return String(value);
        }
      })
      .join(' ');
  }

  const console = {};
  for (const [name, level] of [['log', 'info'], ['info', 'info'], ['debug', 'debug'], ['warn', 'warning'], ['error', 'error']]) {
    console[name] = (...values) => {
      if (systemConsole && typeof systemConsole[name] === 'function') systemConsole[name](...values);
      native.log(level, format(values));
    };
  }
  global.console = console;

  const timers = new Map();
  let nextTimer = 1;

  function addTimer(callback, delay, args, repeat) {
    if (typeof callback !== 'function') throw new TypeError('timer callback must be a function');
    const id = nextTimer++;
    const ms = Math.max(repeat ? 10 : 0, Number(delay) || 0);
    timers.set(id, { callback, args, ms, repeat });
    native.schedule(id, ms);
    return id;
  }

  function fireTimer(id) {
    const timer = timers.get(id);
    if (!timer) return;
    if (timer.repeat) native.schedule(id, timer.ms);
    else timers.delete(id);
    try {
      timer.callback(...timer.args);
    } catch (error) {
      console.error('timer callback threw', error);
    }
  }

  global.setTimeout = (callback, delay, ...args) => addTimer(callback, delay, args, false);
  global.setInterval = (callback, delay, ...args) => addTimer(callback, delay, args, true);
  global.clearTimeout = (id) => void timers.delete(id);
  global.clearInterval = global.clearTimeout;
  global.queueMicrotask = (callback) =>
    void Promise.resolve()
      .then(callback)
      .catch((error) => console.error('microtask threw', error));

  class TextEncoder {
    get encoding() {
      return 'utf-8';
    }

    encode(text = '') {
      return native.utf8Encode(String(text));
    }
  }

  class TextDecoder {
    constructor(label = 'utf-8', options = {}) {
      const encoding = String(label).trim().toLowerCase();
      if (!native.supportsEncoding(encoding)) throw new RangeError(`unsupported encoding: ${label}`);
      this.encoding = encoding;
      this.fatal = Boolean(options.fatal);
      this.ignoreBOM = Boolean(options.ignoreBOM);
    }

    decode(data) {
      return data === undefined ? '' : native.decodeText(toBytes(data), this.encoding);
    }
  }

  global.TextEncoder = TextEncoder;
  global.TextDecoder = TextDecoder;

  global.btoa = (text) => {
    const string = String(text);
    const bytes = new Uint8Array(string.length);
    for (let i = 0; i < string.length; i++) {
      const code = string.charCodeAt(i);
      if (code > 255) throw new Error('btoa: the string has characters outside Latin-1');
      bytes[i] = code;
    }
    return native.base64Encode(bytes);
  };

  global.atob = (text) => {
    const bytes = native.base64Decode(String(text));
    let string = '';
    for (let i = 0; i < bytes.length; i += 8192) string += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    return string;
  };

  function formEncode(text) {
    return encodeURIComponent(text)
      .replace(/[!'()~]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
      .replace(/%20/g, '+');
  }

  function formDecode(text) {
    const spaced = text.replace(/\+/g, ' ');
    try {
      return decodeURIComponent(spaced);
    } catch (error) {
      return spaced;
    }
  }

  function parseQuery(text) {
    const query = text.startsWith('?') ? text.slice(1) : text;
    const list = [];
    for (const part of query.split('&')) {
      if (!part) continue;
      const equals = part.indexOf('=');
      list.push(equals < 0 ? [formDecode(part), ''] : [formDecode(part.slice(0, equals)), formDecode(part.slice(equals + 1))]);
    }
    return list;
  }

  class URLSearchParams {
    constructor(init) {
      this._list = [];
      this._url = null;
      if (init == null) return;
      if (typeof init === 'string') this._list = parseQuery(init);
      else if (init instanceof URLSearchParams) this._list = init._list.map(([key, value]) => [key, value]);
      else if (typeof init[Symbol.iterator] === 'function') for (const [key, value] of init) this._list.push([String(key), String(value)]);
      else for (const key of Object.keys(init)) if (init[key] !== undefined) this._list.push([key, String(init[key])]);
    }

    _changed() {
      if (this._url) this._url._search = this._list.length ? `?${this}` : '';
    }

    get size() {
      return this._list.length;
    }

    append(key, value) {
      this._list.push([String(key), String(value)]);
      this._changed();
    }

    delete(key) {
      this._list = this._list.filter(([name]) => name !== String(key));
      this._changed();
    }

    get(key) {
      const entry = this._list.find(([name]) => name === String(key));
      return entry ? entry[1] : null;
    }

    getAll(key) {
      return this._list.filter(([name]) => name === String(key)).map(([, value]) => value);
    }

    has(key) {
      return this._list.some(([name]) => name === String(key));
    }

    set(key, value) {
      const name = String(key);
      let found = false;
      this._list = this._list.filter((entry) => {
        if (entry[0] !== name) return true;
        if (found) return false;
        found = true;
        entry[1] = String(value);
        return true;
      });
      if (!found) this._list.push([name, String(value)]);
      this._changed();
    }

    sort() {
      this._list.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
      this._changed();
    }

    forEach(callback, thisArg) {
      for (const [key, value] of this._list) callback.call(thisArg, value, key, this);
    }

    keys() {
      return this._list.map(([key]) => key)[Symbol.iterator]();
    }

    values() {
      return this._list.map(([, value]) => value)[Symbol.iterator]();
    }

    entries() {
      return this._list.map(([key, value]) => [key, value])[Symbol.iterator]();
    }

    [Symbol.iterator]() {
      return this.entries();
    }

    toString() {
      return this._list.map(([key, value]) => `${formEncode(key)}=${formEncode(value)}`).join('&');
    }
  }

  class URL {
    constructor(url, base) {
      const parts = native.parseURL(String(url), base === undefined ? undefined : String(base));
      if (!parts) throw new TypeError(`Invalid URL: ${url}`);
      this.protocol = parts.protocol;
      this.username = parts.username;
      this.password = parts.password;
      this.hostname = parts.hostname;
      this.port = parts.port;
      this.pathname = parts.pathname;
      this.hash = parts.hash;
      this._search = parts.search;
      this._params = new URLSearchParams(parts.search);
      this._params._url = this;
    }

    get search() {
      return this._search;
    }

    set search(value) {
      const text = String(value);
      this._search = text && text !== '?' ? (text.startsWith('?') ? text : `?${text}`) : '';
      this._params._list = parseQuery(this._search);
    }

    get searchParams() {
      return this._params;
    }

    get host() {
      return this.port ? `${this.hostname}:${this.port}` : this.hostname;
    }

    get origin() {
      return `${this.protocol}//${this.host}`;
    }

    get href() {
      const auth = this.username ? `${this.username}${this.password ? `:${this.password}` : ''}@` : '';
      return `${this.protocol}//${auth}${this.host}${this.pathname}${this._search}${this.hash}`;
    }

    toString() {
      return this.href;
    }

    toJSON() {
      return this.href;
    }
  }

  global.URL = URL;
  global.URLSearchParams = URLSearchParams;

  function hasHeader(headers, name) {
    return Object.keys(headers).some((key) => key.toLowerCase() === name);
  }

  async function request(options) {
    if (typeof options === 'string') options = { url: options };
    if (!options || options.url === undefined) throw new TypeError('request needs a url');
    let url = String(options.url);
    if (options.query) {
      const target = new URL(url);
      for (const key of Object.keys(options.query)) {
        const value = options.query[key];
        if (value !== undefined && value !== null) target.searchParams.append(key, String(value));
      }
      url = target.href;
    }
    const headers = {};
    for (const key of Object.keys(options.headers || {})) {
      const value = options.headers[key];
      if (value !== undefined && value !== null) headers[key] = String(value);
    }
    let body = options.body;
    if (options.json !== undefined) {
      body = JSON.stringify(options.json);
      if (!hasHeader(headers, 'content-type')) headers['Content-Type'] = 'application/json';
    } else if (options.form !== undefined) {
      body = new URLSearchParams(options.form).toString();
      if (!hasHeader(headers, 'content-type')) headers['Content-Type'] = 'application/x-www-form-urlencoded';
    } else if (body instanceof URLSearchParams) {
      body = body.toString();
      if (!hasHeader(headers, 'content-type')) headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    if (body !== undefined && body !== null && typeof body !== 'string') body = toBytes(body, 'body');
    const hasBody = body !== undefined && body !== null;
    const responseType = options.responseType || 'text';
    const response = await native.http({
      url,
      method: String(options.method || (hasBody ? 'POST' : 'GET')).toUpperCase(),
      headers,
      body: hasBody ? body : undefined,
      timeout: Number(options.timeout) || 15,
      redirect: options.redirect === 'manual' ? 'manual' : 'follow',
      bytes: responseType === 'bytes',
      proxy: options.proxy === undefined || options.proxy === null ? undefined : String(options.proxy),
      cookies: options.cookies !== false,
    });
    if (responseType === 'json') {
      try {
        response.body = JSON.parse(response.body);
      } catch (error) {
        throw starry.error('invalidResponse', `${url} 返回的不是 JSON（HTTP ${response.status}）`);
      }
    }
    return response;
  }

  function bodyOption(body) {
    if (body === undefined || body === null || typeof body === 'string' || body instanceof Uint8Array || body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return { body };
    if (body instanceof URLSearchParams) return { form: body.toString() };
    return { json: body };
  }

  class Headers {
    constructor(init) {
      this._map = new Map();
      if (init instanceof Headers) init.forEach((value, key) => this._map.set(key, value));
      else if (init && typeof init[Symbol.iterator] === 'function') for (const [key, value] of init) this._map.set(String(key).toLowerCase(), String(value));
      else if (init) for (const key of Object.keys(init)) this._map.set(key.toLowerCase(), String(init[key]));
    }

    get(name) {
      const value = this._map.get(String(name).toLowerCase());
      return value === undefined ? null : value;
    }

    has(name) {
      return this._map.has(String(name).toLowerCase());
    }

    set(name, value) {
      this._map.set(String(name).toLowerCase(), String(value));
    }

    append(name, value) {
      const key = String(name).toLowerCase();
      this._map.set(key, this._map.has(key) ? `${this._map.get(key)}, ${value}` : String(value));
    }

    delete(name) {
      this._map.delete(String(name).toLowerCase());
    }

    forEach(callback, thisArg) {
      for (const [key, value] of this._map) callback.call(thisArg, value, key, this);
    }

    entries() {
      return this._map.entries();
    }

    [Symbol.iterator]() {
      return this._map.entries();
    }

    _object() {
      const object = {};
      for (const [key, value] of this._map) object[key] = value;
      return object;
    }
  }

  class Response {
    constructor(response) {
      this.status = response.status;
      this.ok = response.status >= 200 && response.status < 300;
      this.url = response.url;
      this.headers = new Headers(response.headers);
      this._bytes = response.body;
    }

    async arrayBuffer() {
      return this._bytes.buffer.slice(this._bytes.byteOffset, this._bytes.byteOffset + this._bytes.byteLength);
    }

    async bytes() {
      return this._bytes;
    }

    async text() {
      const match = /charset=([^;]+)/i.exec(this.headers.get('content-type') || '');
      const charset = match ? match[1].trim().replace(/"/g, '').toLowerCase() : 'utf-8';
      return native.decodeText(this._bytes, native.supportsEncoding(charset) ? charset : 'utf-8');
    }

    async json() {
      return JSON.parse(await this.text());
    }
  }

  global.Headers = Headers;
  global.Response = Response;
  global.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : String(input && input.url);
    const headers = init.headers instanceof Headers ? init.headers._object() : new Headers(init.headers)._object();
    const response = await request({
      url,
      method: init.method,
      headers,
      body: init.body,
      redirect: init.redirect === 'manual' ? 'manual' : 'follow',
      responseType: 'bytes',
    });
    return new Response(response);
  };

  let settings = Object.freeze({});

  function symmetric(algorithm, decrypt) {
    return (options) => {
      const bytes = native.cipher({
        algorithm,
        decrypt,
        mode: String(options.mode || 'cbc').toLowerCase(),
        key: toBytes(options.key, 'key'),
        iv: options.iv === undefined ? undefined : toBytes(options.iv, 'iv'),
        aad: options.aad === undefined ? undefined : toBytes(options.aad, 'aad'),
        data: toBytes(options.data),
        padding: options.padding !== false,
      });
      return output(bytes, options.out);
    };
  }

  const crypto = {
    hmac: (algorithm, key, data, encoding) => output(native.hmac(String(algorithm).toLowerCase(), toBytes(key, 'key'), toBytes(data)), encoding),
    aes: { encrypt: symmetric('aes', false), decrypt: symmetric('aes', true) },
    des: { encrypt: symmetric('des', false), decrypt: symmetric('des', true) },
    tripleDES: { encrypt: symmetric('3des', false), decrypt: symmetric('3des', true) },
    rsa: {
      encrypt: (options) =>
        output(native.rsaEncrypt({ publicKey: String(options.publicKey), data: toBytes(options.data), padding: String(options.padding || 'pkcs1') }), options.out),
    },
    randomBytes: (count) => native.randomBytes(Math.max(0, Number(count) | 0)),
  };
  for (const name of ['md5', 'sha1', 'sha256', 'sha384', 'sha512']) crypto[name] = (data, encoding) => output(native.hash(name, toBytes(data)), encoding);

  const starry = {
    apiVersion: 1,
    plugin: Object.freeze({}),
    app: Object.freeze({}),
    get settings() {
      return settings;
    },
    error(code, message) {
      const error = new Error(message === undefined ? String(code) : String(message));
      error.code = String(code);
      return error;
    },
    http: {
      request,
      get: (url, options = {}) => request({ ...options, url, method: 'GET' }),
      post: (url, body, options = {}) => request({ ...options, ...bodyOption(body), url, method: 'POST' }),
    },
    crypto,
    encoding: {
      utf8: { encode: (text) => native.utf8Encode(String(text)), decode: (data) => native.decodeText(toBytes(data), 'utf-8') },
      hex: { encode: hexEncode, decode: hexDecode },
      base64: { encode: (data) => native.base64Encode(toBytes(data)), decode: (text) => native.base64Decode(String(text)) },
    },
    zlib: {
      inflate: (data, encoding) => output(native.inflate(toBytes(data)), encoding),
      deflate: (data, options = {}) => output(native.deflate(toBytes(data), String(options.format || 'zlib')), options.out),
    },
    setWebPages(pages) {
      if (pages === null || pages === undefined) return void native.setWebPages(null);
      if (typeof pages !== 'object') throw new TypeError('setWebPages takes an object of URL templates, or null');
      const templates = {};
      for (const [kind, template] of Object.entries(pages)) {
        if (typeof template === 'string') templates[kind] = template;
      }
      native.setWebPages(JSON.stringify(templates));
    },
    storage: {
      get(key) {
        const text = native.storageGet(String(key));
        return text === undefined ? undefined : JSON.parse(text);
      },
      set(key, value) {
        if (value === undefined) return void native.storageRemove(String(key));
        const text = JSON.stringify(value);
        if (text === undefined) throw new TypeError('storage values must be JSON');
        native.storageSet(String(key), text);
      },
      remove: (key) => void native.storageRemove(String(key)),
      keys: () => native.storageKeys(),
      clear: () => void native.storageClear(),
    },
  };
  global.starry = starry;

  const module = { exports: {} };
  global.module = module;
  global.exports = module.exports;

  function plugin() {
    const exported = module.exports;
    if (exported && typeof exported === 'object') {
      if (exported.id === undefined && exported.default && typeof exported.default === 'object') return exported.default;
      return exported;
    }
    return {};
  }

  function errorInfo(error) {
    if (error && typeof error === 'object') {
      return {
        code: error.code === undefined || error.code === null ? null : String(error.code),
        message: String(error.message !== undefined ? error.message : format([error])),
        stack: error.stack ? String(error.stack) : null,
      };
    }
    return { code: null, message: String(error), stack: null };
  }

  const resultReplacer = (key, value) => (value instanceof Uint8Array ? native.base64Encode(value) : typeof value === 'bigint' ? value.toString() : value);

  const sourceFunctions = [
    'resolve', 'decryptor', 'search', 'searchOverview', 'searchSuggestions', 'trendingSearches', 'searchHints',
    'songs', 'album', 'artist', 'artistSongs', 'artistAlbums', 'similarArtists', 'playlist',
    'recommendedPlaylists', 'newSongs', 'newAlbums', 'topArtists',
    'user', 'playlistsOfUser', 'listeningRanking', 'follows', 'followers', 'setUserFollowed',
    'userPlaylists', 'likedPlaylistID', 'likedTrackIDs', 'setLiked', 'setCollected',
    'dailyRecommendations', 'dailyPlaylists', 'personalFM', 'skipFM', 'trashFM', 'allMedia', 'homeShelves',
    'comments', 'commentThread', 'replies', 'setCommentLiked', 'reportPlayback',
    'createPlaylist', 'editPlaylist', 'deletePlaylist', 'addToPlaylist', 'removeFromPlaylist', 'reorderPlaylist',
    'libraryAlbums', 'libraryArtists', 'libraryGenres',
  ];

  const accountFunctions = [
    'current', 'refresh', 'connect', 'beginQRLogin', 'pollQRLogin', 'beginCodeLogin', 'pollCodeLogin', 'loginWithCookie', 'loginWithPassword',
    'sendPhoneCode', 'loginWithPhoneCode', 'logout', 'signOutLocally', 'exportCredentials', 'restoreCredentials',
  ];

  function group(value) {
    return value && typeof value === 'object' ? value : null;
  }

  function functions(object, names) {
    return names.filter((name) => typeof object[name] === 'function');
  }

  return {
    invoke(path, argumentsJSON) {
      return new Promise((resolve) => {
        let owner = null;
        let target = plugin();
        for (const part of path.split('.')) {
          owner = target;
          target = target === null || target === undefined ? undefined : target[part];
        }
        if (typeof target !== 'function') throw starry.error('notSupported', `插件没有实现 ${path}`);
        resolve(target.apply(owner, JSON.parse(argumentsJSON)));
      })
        .then((value) => JSON.stringify(value === undefined ? null : value, resultReplacer))
        .catch((error) => {
          throw JSON.stringify(errorInfo(error));
        });
    },

    describe() {
      const exported = plugin();
      const source = group(exported.source);
      const lyrics = group(exported.lyrics);
      const account = group(exported.account);
      return JSON.stringify({
        id: exported.id,
        name: exported.name,
        version: exported.version,
        apiVersion: exported.apiVersion,
        author: exported.author,
        description: exported.description,
        homepage: exported.homepage,
        icon: exported.icon,
        idNamespace: exported.idNamespace,
        permissions: group(exported.permissions) || {},
        settings: Array.isArray(exported.settings) ? exported.settings : [],
        source: source && {
          functions: functions(source, sourceFunctions),
          qualityTiers: source.qualityTiers,
          webPages: source.webPages,
          searchKinds: source.searchKinds,
          artistSongOrders: source.artistSongOrders,
          collectableKinds: source.collectableKinds,
          commentSorts: source.commentSorts,
          canLikeComments: source.canLikeComments,
          playlistOptions: group(source.playlistOptions),
          albumSorts: source.albumSorts,
        },
        lyrics: lyrics && { functions: functions(lyrics, ['search', 'fetch']), detail: lyrics.detail, ttmlFolder: lyrics.ttmlFolder },
        account: account && {
          functions: functions(account, accountFunctions),
          methods: account.methods,
          qrKinds: account.qrKinds,
          cookieHint: account.cookieHint,
          multipleAccounts: account.multipleAccounts,
          server: group(account.server),
          passwordOptional: account.passwordOptional,
          codeLogin: group(account.codeLogin),
        },
      });
    },

    makeDecryptor(parametersJSON) {
      const source = group(plugin().source);
      if (!source || typeof source.decryptor !== 'function') throw new Error('插件没有实现 source.decryptor');
      const decrypt = source.decryptor(JSON.parse(parametersJSON));
      if (typeof decrypt !== 'function') throw new Error('source.decryptor 应返回 (bytes, offset) => void');
      return decrypt;
    },

    fireTimer,

    setInfo(json) {
      const info = JSON.parse(json);
      starry.plugin = Object.freeze(info.plugin);
      starry.app = Object.freeze(info.app);
    },

    setSettings(json, notify) {
      settings = Object.freeze(JSON.parse(json));
      const handler = plugin().onSettingsChanged;
      if (notify && typeof handler === 'function') {
        Promise.resolve()
          .then(() => handler.call(plugin(), settings))
          .catch((error) => console.error('onSettingsChanged threw', error));
      }
    },
  };
})(globalThis, globalThis.__starryNative);
