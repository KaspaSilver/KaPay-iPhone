// Trestly's kUSDT wallet logic, kaspador/kusdt-open b70707c (wallet/extension/src/kusdt), built for KaPay by tools/kusdt-wallet.
var __getOwnPropNames = Object.getOwnPropertyNames;
var __esm = (fn, res, err) => function __init() {
  if (err) throw err[0];
  try {
    return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
  } catch (e) {
    throw err = [e], e;
  }
};

// node_modules/@noble/hashes/_u64.js
function add(Ah, Al, Bh, Bl) {
  const l = (Al >>> 0) + (Bl >>> 0);
  return { h: Ah + Bh + (l / 2 ** 32 | 0) | 0, l: l | 0 };
}
var fromNumH, fromNumL, rotrSH, rotrSL, rotrBH, rotrBL, rotr32H, rotr32L, add3L, add3H;
var init_u64 = __esm({
  "node_modules/@noble/hashes/_u64.js"() {
    fromNumH = (n) => n / 2 ** 32 | 0;
    fromNumL = (n) => n >>> 0;
    rotrSH = (h, l, s) => h >>> s | l << 32 - s;
    rotrSL = (h, l, s) => h << 32 - s | l >>> s;
    rotrBH = (h, l, s) => h << 64 - s | l >>> s - 32;
    rotrBL = (h, l, s) => h >>> s - 32 | l << 64 - s;
    rotr32H = (_h, l) => l;
    rotr32L = (h, _l) => h;
    add3L = (Al, Bl, Cl) => (Al >>> 0) + (Bl >>> 0) + (Cl >>> 0);
    add3H = (low, Ah, Bh, Ch) => Ah + Bh + Ch + (low / 2 ** 32 | 0) | 0;
  }
});

// node_modules/@noble/hashes/utils.js
function isBytes(a) {
  return a instanceof Uint8Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint8Array" && "BYTES_PER_ELEMENT" in a && a.BYTES_PER_ELEMENT === 1;
}
function anumber(n, title = "") {
  if (typeof n !== "number")
    throw new TypeError(atitle(title) + "expected number, got " + typeof n);
  if (!Number.isSafeInteger(n) || n < 0)
    throw new RangeError(atitle(title) + "expected integer >= 0, got " + n);
  return n;
}
function abytes(value, length, title = "") {
  if (isBytes(value) && (length === void 0 || value.length === length))
    return value;
  if (length !== void 0)
    anumber(length, "length");
  const bytes = isBytes(value);
  const ofLen = length !== void 0 ? ` of length ${length}` : "";
  const got = bytes ? `length=${value.length}` : `type=${typeof value}`;
  const message = atitle(title) + "expected Uint8Array" + ofLen + ", got " + got;
  if (!bytes)
    throw new TypeError(message);
  throw new RangeError(message);
}
function copyBytes(bytes) {
  return Uint8Array.from(abytes(bytes));
}
function aexists(instance, checkFinished = true) {
  if (instance.destroyed)
    throw new Error("hash was destroyed");
  if (checkFinished && instance.finished)
    throw new Error("digest() was already called");
}
function aoutput(out, instance) {
  abytes(out, void 0, "output");
  const min = instance.outputLen;
  if (!(out.length >= min)) {
    throw new RangeError('"output" expected length >= ' + min);
  }
}
function u8(arr) {
  return new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength);
}
function u32(arr) {
  return new Uint32Array(arr.buffer, arr.byteOffset, Math.floor(arr.byteLength / 4));
}
function clean(...arrays) {
  for (let i = 0; i < arrays.length; i++) {
    arrays[i].fill(0);
  }
}
function rotr(word, shift) {
  return word << 32 - shift | word >>> shift;
}
function byteSwap(word) {
  return word << 24 & 4278190080 | word << 8 & 16711680 | word >>> 8 & 65280 | word >>> 24 & 255;
}
function byteSwap32(arr) {
  for (let i = 0; i < arr.length; i++) {
    arr[i] = byteSwap(arr[i]);
  }
  return arr;
}
function checkOpts(defaults, opts, title = "opts") {
  aopts(defaults, "defaults");
  if (opts !== void 0)
    aopts(opts, title);
  const merged = Object.assign(/* @__PURE__ */ Object.create(null), defaults, opts);
  return merged;
}
function createHasher(hashCons, info = {}) {
  if (typeof hashCons !== "function")
    throw new TypeError('"hashCons" expected function, got type=' + typeof hashCons);
  info = checkOpts({}, info, "info");
  const hashC = (msg, opts) => hashCons(opts).update(msg).digest();
  const tmp = hashCons(void 0);
  hashC.outputLen = tmp.outputLen;
  hashC.blockLen = tmp.blockLen;
  hashC.canXOF = tmp.canXOF;
  hashC.create = (opts) => hashCons(opts);
  Object.assign(hashC, info);
  return Object.freeze(hashC);
}
var atitle, aobject, aopts, isLE, swap8IfBE, swap32IfBE;
var init_utils = __esm({
  "node_modules/@noble/hashes/utils.js"() {
    atitle = (title) => title ? `"${title}" ` : "";
    aobject = (value, label) => {
      if (value === null || typeof value !== "object" || Array.isArray(value))
        throw new TypeError((label === "object" ? "" : `"${label}" `) + "expected object, got type=" + typeof value);
    };
    aopts = (value, label) => {
      aobject(value, label);
      const proto = Object.getPrototypeOf(value);
      if (proto !== Object.prototype && proto !== null)
        throw new TypeError(`"${label}" expected plain object`);
      if (Object.hasOwn(value, "__proto__"))
        throw new TypeError(`"${label}.__proto__" is not allowed`);
    };
    isLE = /* @__PURE__ */ (() => new Uint8Array(new Uint32Array([287454020]).buffer)[0] === 68)();
    swap8IfBE = isLE ? (n) => n : (n) => byteSwap(n) >>> 0;
    swap32IfBE = isLE ? (u) => u : byteSwap32;
  }
});

// node_modules/@noble/hashes/_md.js
var SHA256_IV;
var init_md = __esm({
  "node_modules/@noble/hashes/_md.js"() {
    SHA256_IV = /* @__PURE__ */ Uint32Array.from([
      1779033703,
      3144134277,
      1013904242,
      2773480762,
      1359893119,
      2600822924,
      528734635,
      1541459225
    ]);
  }
});

// src/shims.ts
var handlers = globalThis.webkit?.messageHandlers ?? {};
var post = (name, message) => {
  const h = handlers[name];
  if (!h) return Promise.reject(new Error(`KaPay bridge ${name} is missing`));
  return h.postMessage(message);
};
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
  const headers = {};
  new Headers(init?.headers ?? (input instanceof Request ? input.headers : void 0)).forEach((v, k) => {
    headers[k] = v;
  });
  const body = typeof init?.body === "string" ? init.body : null;
  if (init?.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  const answer = await post("kusdtNet", { url, method, headers, body });
  if (init?.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  if (answer.error) throw new TypeError(answer.error);
  const status = answer.status ?? 0;
  const noBody = status === 204 || status === 304 || method === "HEAD";
  return new Response(noBody ? null : answer.body ?? "", { status, headers: answer.headers ?? {} });
};
var area = {
  get(keys, callback) {
    const list = Array.isArray(keys) ? keys : [keys];
    post("kusdtStore", { op: "get", keys: list }).then((a) => callback(a.value ?? {}), () => callback({}));
  },
  set(values, callback) {
    post("kusdtStore", { op: "set", values: JSON.parse(JSON.stringify(values)) }).then(() => callback?.(), () => callback?.());
  },
  remove(keys, callback) {
    post("kusdtStore", { op: "remove", keys: Array.isArray(keys) ? keys : [keys] }).then(() => callback?.(), () => callback?.());
  }
};
globalThis.chrome = { storage: { local: area }, runtime: {} };

// src/entry.ts
import * as wasm from "./kusdt_wasm.js";

// ../../../kusdt-open/bridge/packages/core/src/exactJson.ts
var MAX_INTEGER_DIGITS = 78;
function exactInteger(token) {
  const m = /^(-?)(0|[1-9]\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(token);
  if (!m) return null;
  const digits = m[2] + (m[3] ?? "");
  const point = m[2].length + (m[4] ? Number(m[4]) : 0);
  const first = digits.search(/[1-9]/);
  if (first < 0) return null;
  if (digits.slice(Math.max(point, 0)).search(/[1-9]/) >= 0) return null;
  const count = point - first;
  if (count < 16) return null;
  if (count > MAX_INTEGER_DIGITS) return token;
  return m[1] + digits.slice(first, point).padEnd(count, "0");
}
function quoteLargeIntegers(text) {
  let out = "";
  let copied = 0;
  let i = 0;
  while (i < text.length) {
    const c = text.charCodeAt(i);
    if (c === 34) {
      i++;
      while (i < text.length && text.charCodeAt(i) !== 34) i += text.charCodeAt(i) === 92 ? 2 : 1;
      i++;
    } else if (c === 45 || c >= 48 && c <= 57) {
      const start = i;
      i++;
      for (; i < text.length; i++) {
        const d = text.charCodeAt(i);
        if (!(d >= 48 && d <= 57 || d === 46 || d === 101 || d === 69 || d === 43 || d === 45)) break;
      }
      const exact = exactInteger(text.slice(start, i));
      if (exact !== null) {
        out += text.slice(copied, start) + '"' + exact + '"';
        copied = i;
      }
    } else i++;
  }
  return copied === 0 ? text : out + text.slice(copied);
}
function parseExactJson(text) {
  return JSON.parse(quoteLargeIntegers(text));
}
function stringifyExact(value) {
  if (typeof value === "bigint") return value.toString();
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  const toJson = value.toJSON;
  if (typeof toJson === "function") return stringifyExact(toJson.call(value));
  if (Array.isArray(value)) return `[${value.map((v) => stringifyExact(v) ?? "null").join(",")}]`;
  const fields = [];
  for (const [k, v] of Object.entries(value)) {
    const written = stringifyExact(v);
    if (written !== void 0) fields.push(`${JSON.stringify(k)}:${written}`);
  }
  return `{${fields.join(",")}}`;
}

// ../../../kusdt-open/bridge/packages/core/src/core.ts
var CoreError = class extends Error {
  constructor(command, message) {
    super(`${command}: ${message}`);
    this.command = command;
  }
  command;
};
function requestJson(request) {
  return stringifyExact(request) ?? "null";
}
function parseAnswer(text) {
  return parseExactJson(text);
}
function makeCore(module) {
  const call = (command, request = {}) => {
    const raw = module.run(command, typeof request === "string" ? request : requestJson(request));
    const value = parseAnswer(raw);
    if (value && typeof value === "object" && "error" in value && Object.keys(value).length === 1) throw new CoreError(command, String(value.error));
    return { value, raw };
  };
  return {
    call,
    commands: () => JSON.parse(module.commands()),
    version: () => module.version()
  };
}

// ../../../kusdt-open/bridge/packages/kaspa/src/bytes.ts
function bytesToHex(bytes) {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}
function hexToBytes(hex) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length % 2 !== 0 || /[^0-9a-fA-F]/.test(h)) throw new Error("Bad hex.");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}
function concatBytes(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

// ../../../kusdt-open/bridge/packages/kaspa/src/address.ts
var CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
var PAYLOAD_LEN = { 0: 32, 1: 33, 8: 32 };
var PREFIXES = /* @__PURE__ */ new Set(["kaspa", "kaspatest", "kaspasim", "kaspadev"]);
var GEN = [0x98f2bc8e61n, 0x79b76d99e2n, 0xf33e5fb3c4n, 0xae2eabe2a8n, 0x1e4f43e470n];
function polymod(values) {
  let c = 1n;
  for (const d of values) {
    const c0 = c >> 35n;
    c = (c & 0x07ffffffffn) << 5n ^ BigInt(d);
    for (let i = 0; i < 5; i++) if (c0 >> BigInt(i) & 1n) c ^= GEN[i];
  }
  return c ^ 1n;
}
function checksum(prefix, data5) {
  const pre = Array.from(prefix, (ch) => ch.charCodeAt(0) & 31);
  return polymod([...pre, 0, ...data5, 0, 0, 0, 0, 0, 0, 0, 0]);
}
function conv8to5(bytes) {
  const out = [];
  let buff = 0, bits = 0;
  for (const b of bytes) {
    buff = buff << 8 | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.push(buff >> bits & 31);
      buff &= (1 << bits) - 1;
    }
  }
  if (bits > 0) out.push(buff << 5 - bits & 31);
  return out;
}
function conv5to8(data) {
  const out = [];
  let buff = 0, bits = 0;
  for (const d of data) {
    buff = buff << 5 | d;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.push(buff >> bits & 255);
      buff &= (1 << bits) - 1;
    }
  }
  return Uint8Array.from(out);
}
function encodeKaspaAddress(prefix, version, payload) {
  if (payload.length !== PAYLOAD_LEN[version]) throw new Error("Wrong payload length for this address version.");
  const data5 = conv8to5(Uint8Array.from([version, ...payload]));
  const sum = checksum(prefix, data5);
  const sumBytes = new Uint8Array(5);
  for (let i = 0; i < 5; i++) sumBytes[i] = Number(sum >> BigInt(8 * (4 - i)) & 0xffn);
  return `${prefix}:${[...data5, ...conv8to5(sumBytes)].map((d) => CHARSET[d]).join("")}`;
}
function decodeKaspaAddress(address) {
  if (typeof address !== "string" || address !== address.toLowerCase()) return null;
  const sep = address.indexOf(":");
  if (sep <= 0 || address.indexOf(":", sep + 1) !== -1) return null;
  const prefix = address.slice(0, sep);
  const body = address.slice(sep + 1);
  if (!PREFIXES.has(prefix) || body.length < 9) return null;
  const data = [];
  for (const ch of body) {
    const v = CHARSET.indexOf(ch);
    if (v < 0) return null;
    data.push(v);
  }
  const payload5 = data.slice(0, -8);
  const sum5 = data.slice(-8);
  const sumBytes = conv5to8(sum5);
  let sum = 0n;
  for (const b of sumBytes) sum = sum << 8n | BigInt(b);
  if (checksum(prefix, payload5) !== sum) return null;
  const bytes = conv5to8(payload5);
  const version = bytes[0];
  if (!(version in PAYLOAD_LEN)) return null;
  const payload = bytes.slice(1);
  if (payload.length !== PAYLOAD_LEN[version]) return null;
  return { prefix, version, payload };
}
function scriptForAddress(address, prefix) {
  const d = decodeKaspaAddress(address);
  if (!d) throw new Error("Invalid Kaspa address.");
  if (d.prefix !== prefix) throw new Error(`That is a ${d.prefix}: address, not ${prefix}:.`);
  switch (d.version) {
    case 0:
      return { version: 0, script: Uint8Array.from([32, ...d.payload, 172]) };
    case 1:
      return { version: 0, script: Uint8Array.from([33, ...d.payload, 171]) };
    case 8:
      return { version: 0, script: Uint8Array.from([170, 32, ...d.payload, 135]) };
  }
}
function addressForScript(spk, prefix) {
  const s = spk.script;
  if (spk.version !== 0) return null;
  if (s.length === 34 && s[0] === 32 && s[33] === 172) return encodeKaspaAddress(prefix, 0, s.slice(1, 33));
  if (s.length === 35 && s[0] === 33 && s[34] === 171) return encodeKaspaAddress(prefix, 1, s.slice(1, 34));
  if (s.length === 35 && s[0] === 170 && s[1] === 32 && s[34] === 135) return encodeKaspaAddress(prefix, 8, s.slice(2, 34));
  return null;
}

// ../../../kusdt-open/bridge/packages/kaspa/src/network.ts
var KASPA_NETWORKS = {
  mainnet: {
    name: "mainnet",
    prefix: "kaspa",
    api: "https://api.kaspa.org",
    explorerTx: "https://explorer.kaspa.org/txs/{id}",
    explorerAddress: "https://explorer.kaspa.org/addresses/{address}"
  },
  "testnet-10": {
    name: "testnet-10",
    prefix: "kaspatest",
    api: "https://api-tn10.kaspa.org",
    explorerTx: "https://tn10.kaspa.stream/transactions/{id}",
    explorerAddress: "https://tn10.kaspa.stream/addresses/{address}"
  },
  simnet: { name: "simnet", prefix: "kaspasim", api: "", explorerTx: "", explorerAddress: "" },
  devnet: { name: "devnet", prefix: "kaspadev", api: "", explorerTx: "", explorerAddress: "" }
};

// node_modules/@noble/hashes/_blake.js
init_utils();
var BSIGMA = /* @__PURE__ */ Uint8Array.from([
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  14,
  10,
  4,
  8,
  9,
  15,
  13,
  6,
  1,
  12,
  0,
  2,
  11,
  7,
  5,
  3,
  11,
  8,
  12,
  0,
  5,
  2,
  15,
  13,
  10,
  14,
  3,
  6,
  7,
  1,
  9,
  4,
  7,
  9,
  3,
  1,
  13,
  12,
  11,
  14,
  2,
  6,
  5,
  10,
  4,
  0,
  15,
  8,
  9,
  0,
  5,
  7,
  2,
  4,
  10,
  15,
  14,
  1,
  11,
  12,
  6,
  8,
  3,
  13,
  2,
  12,
  6,
  10,
  0,
  11,
  8,
  3,
  4,
  13,
  7,
  5,
  15,
  14,
  1,
  9,
  12,
  5,
  1,
  15,
  14,
  13,
  4,
  10,
  0,
  7,
  6,
  3,
  9,
  2,
  8,
  11,
  13,
  11,
  7,
  14,
  12,
  1,
  3,
  9,
  5,
  0,
  15,
  4,
  8,
  6,
  2,
  10,
  6,
  15,
  14,
  9,
  11,
  3,
  0,
  8,
  12,
  2,
  13,
  7,
  1,
  4,
  10,
  5,
  10,
  2,
  8,
  4,
  7,
  6,
  1,
  5,
  15,
  11,
  9,
  14,
  3,
  12,
  13,
  0,
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  14,
  10,
  4,
  8,
  9,
  15,
  13,
  6,
  1,
  12,
  0,
  2,
  11,
  7,
  5,
  3,
  // Blake1, unused in others
  11,
  8,
  12,
  0,
  5,
  2,
  15,
  13,
  10,
  14,
  3,
  6,
  7,
  1,
  9,
  4,
  7,
  9,
  3,
  1,
  13,
  12,
  11,
  14,
  2,
  6,
  5,
  10,
  4,
  0,
  15,
  8,
  9,
  0,
  5,
  7,
  2,
  4,
  10,
  15,
  14,
  1,
  11,
  12,
  6,
  8,
  3,
  13,
  2,
  12,
  6,
  10,
  0,
  11,
  8,
  3,
  4,
  13,
  7,
  5,
  15,
  14,
  1,
  9
]);
function G1s(a, b, c, d, x) {
  a = a + b + x | 0;
  d = rotr(d ^ a, 16);
  c = c + d | 0;
  b = rotr(b ^ c, 12);
  return { a, b, c, d };
}
function G2s(a, b, c, d, x) {
  a = a + b + x | 0;
  d = rotr(d ^ a, 8);
  c = c + d | 0;
  b = rotr(b ^ c, 7);
  return { a, b, c, d };
}

// node_modules/@noble/hashes/blake2.js
init_u64();
init_utils();
var B2B_IV = /* @__PURE__ */ Uint32Array.from([
  4089235720,
  1779033703,
  2227873595,
  3144134277,
  4271175723,
  1013904242,
  1595750129,
  2773480762,
  2917565137,
  1359893119,
  725511199,
  2600822924,
  4215389547,
  528734635,
  327033209,
  1541459225
]);
var BBUF = /* @__PURE__ */ new Uint32Array(32);
function G1b(a, b, c, d, msg, x) {
  const Xl = msg[x], Xh = msg[x + 1];
  let Al = BBUF[2 * a], Ah = BBUF[2 * a + 1];
  let Bl = BBUF[2 * b], Bh = BBUF[2 * b + 1];
  let Cl = BBUF[2 * c], Ch = BBUF[2 * c + 1];
  let Dl = BBUF[2 * d], Dh = BBUF[2 * d + 1];
  const ll = add3L(Al, Bl, Xl);
  Ah = add3H(ll, Ah, Bh, Xh);
  Al = ll | 0;
  let xh = Dh ^ Ah, xl = Dl ^ Al;
  Dh = rotr32H(xh, xl);
  Dl = rotr32L(xh, xl);
  ({ h: Ch, l: Cl } = add(Ch, Cl, Dh, Dl));
  xh = Bh ^ Ch;
  xl = Bl ^ Cl;
  Bh = rotrSH(xh, xl, 24);
  Bl = rotrSL(xh, xl, 24);
  BBUF[2 * a] = Al;
  BBUF[2 * a + 1] = Ah;
  BBUF[2 * b] = Bl;
  BBUF[2 * b + 1] = Bh;
  BBUF[2 * c] = Cl;
  BBUF[2 * c + 1] = Ch;
  BBUF[2 * d] = Dl;
  BBUF[2 * d + 1] = Dh;
}
function G2b(a, b, c, d, msg, x) {
  const Xl = msg[x], Xh = msg[x + 1];
  let Al = BBUF[2 * a], Ah = BBUF[2 * a + 1];
  let Bl = BBUF[2 * b], Bh = BBUF[2 * b + 1];
  let Cl = BBUF[2 * c], Ch = BBUF[2 * c + 1];
  let Dl = BBUF[2 * d], Dh = BBUF[2 * d + 1];
  const ll = add3L(Al, Bl, Xl);
  Ah = add3H(ll, Ah, Bh, Xh);
  Al = ll | 0;
  let xh = Dh ^ Ah, xl = Dl ^ Al;
  Dh = rotrSH(xh, xl, 16);
  Dl = rotrSL(xh, xl, 16);
  ({ h: Ch, l: Cl } = add(Ch, Cl, Dh, Dl));
  xh = Bh ^ Ch;
  xl = Bl ^ Cl;
  Bh = rotrBH(xh, xl, 63);
  Bl = rotrBL(xh, xl, 63);
  BBUF[2 * a] = Al;
  BBUF[2 * a + 1] = Ah;
  BBUF[2 * b] = Bl;
  BBUF[2 * b + 1] = Bh;
  BBUF[2 * c] = Cl;
  BBUF[2 * c + 1] = Ch;
  BBUF[2 * d] = Dl;
  BBUF[2 * d + 1] = Dh;
}
function checkBlake2Opts(outputLen, opts = {}, keyLen, saltLen, persLen) {
  anumber(keyLen);
  if (outputLen <= 0 || outputLen > keyLen)
    throw new Error('"dkLen" must be 1..' + keyLen + ", got " + outputLen);
  const { key, salt, personalization } = opts;
  if (key !== void 0 && (key.length < 1 || key.length > keyLen))
    throw new Error('"key" expected to be undefined or of length=1..' + keyLen);
  if (salt !== void 0)
    abytes(salt, saltLen, "salt");
  if (personalization !== void 0)
    abytes(personalization, persLen, "personalization");
}
var _BLAKE2 = class {
  buffer;
  buffer32;
  finished = false;
  destroyed = false;
  length = 0;
  pos = 0;
  blockLen;
  outputLen;
  canXOF = false;
  constructor(blockLen, outputLen) {
    anumber(blockLen);
    anumber(outputLen);
    this.blockLen = blockLen;
    this.outputLen = outputLen;
    this.buffer = new Uint8Array(blockLen);
    this.buffer32 = u32(this.buffer);
  }
  update(data) {
    aexists(this);
    abytes(data);
    const { blockLen, buffer, buffer32 } = this;
    const len = data.length;
    const offset = data.byteOffset;
    const buf = data.buffer;
    for (let pos = 0; pos < len; ) {
      if (this.pos === blockLen) {
        swap32IfBE(buffer32);
        this.compress(buffer32, 0, false);
        swap32IfBE(buffer32);
        this.pos = 0;
      }
      const take = Math.min(blockLen - this.pos, len - pos);
      const dataOffset = offset + pos;
      if (take === blockLen && !(dataOffset % 4) && pos + take < len) {
        const data32 = new Uint32Array(buf, dataOffset, Math.floor((len - pos) / 4));
        swap32IfBE(data32);
        for (let pos32 = 0; pos + blockLen < len; pos32 += buffer32.length, pos += blockLen) {
          this.length += blockLen;
          this.compress(data32, pos32, false);
        }
        swap32IfBE(data32);
        continue;
      }
      buffer.set(pos === 0 && take === len ? data : data.subarray(pos, pos + take), this.pos);
      this.pos += take;
      this.length += take;
      pos += take;
    }
    return this;
  }
  digestInto(out) {
    aexists(this);
    aoutput(out, this);
    if (out.byteOffset & 3)
      throw new RangeError('"output" expected 4-byte aligned byteOffset, got ' + out.byteOffset);
    const { pos, buffer32 } = this;
    this.finished = true;
    this.buffer.fill(0, pos);
    swap32IfBE(buffer32);
    this.compress(buffer32, 0, true);
    swap32IfBE(buffer32);
    const state = this.get();
    const out32 = out === this.buffer ? buffer32 : u32(out);
    const full = Math.floor(this.outputLen / 4);
    for (let i = 0; i < full; i++)
      out32[i] = swap8IfBE(state[i]);
    const tail = this.outputLen % 4;
    if (!tail)
      return;
    const off = full * 4;
    const word = state[full];
    for (let i = 0; i < tail; i++)
      out[off + i] = word >>> 8 * i;
  }
  digest() {
    const { buffer, outputLen } = this;
    this.digestInto(buffer);
    const res = buffer.slice(0, outputLen);
    this.destroy();
    return res;
  }
  _cloneInto(to) {
    const { buffer, length, finished, destroyed, outputLen, pos } = this;
    to ||= new this.constructor({ dkLen: outputLen });
    to.set(...this.get());
    to.buffer.set(buffer);
    to.destroyed = destroyed;
    to.finished = finished;
    to.length = length;
    to.pos = pos;
    to.outputLen = outputLen;
    return to;
  }
  clone() {
    return this._cloneInto();
  }
};
var _BLAKE2b = class extends _BLAKE2 {
  // Same IV words as SHA-512 / BLAKE2b, encoded as LE u32 low/high halves.
  v0l = B2B_IV[0] | 0;
  v0h = B2B_IV[1] | 0;
  v1l = B2B_IV[2] | 0;
  v1h = B2B_IV[3] | 0;
  v2l = B2B_IV[4] | 0;
  v2h = B2B_IV[5] | 0;
  v3l = B2B_IV[6] | 0;
  v3h = B2B_IV[7] | 0;
  v4l = B2B_IV[8] | 0;
  v4h = B2B_IV[9] | 0;
  v5l = B2B_IV[10] | 0;
  v5h = B2B_IV[11] | 0;
  v6l = B2B_IV[12] | 0;
  v6h = B2B_IV[13] | 0;
  v7l = B2B_IV[14] | 0;
  v7h = B2B_IV[15] | 0;
  constructor(opts = {}) {
    opts = checkOpts({}, opts);
    const olen = opts.dkLen === void 0 ? 64 : opts.dkLen;
    super(128, olen);
    checkBlake2Opts(olen, opts, 64, 16, 16);
    let { key, personalization, salt } = opts;
    let keyLength = 0;
    if (key !== void 0) {
      abytes(key, void 0, "key");
      keyLength = key.length;
    }
    this.v0l ^= this.outputLen | keyLength << 8 | 1 << 16 | 1 << 24;
    if (salt !== void 0) {
      abytes(salt, void 0, "salt");
      const slt = u32(copyBytes(salt));
      this.v4l ^= swap8IfBE(slt[0]);
      this.v4h ^= swap8IfBE(slt[1]);
      this.v5l ^= swap8IfBE(slt[2]);
      this.v5h ^= swap8IfBE(slt[3]);
    }
    if (personalization !== void 0) {
      abytes(personalization, void 0, "personalization");
      const pers = u32(copyBytes(personalization));
      this.v6l ^= swap8IfBE(pers[0]);
      this.v6h ^= swap8IfBE(pers[1]);
      this.v7l ^= swap8IfBE(pers[2]);
      this.v7h ^= swap8IfBE(pers[3]);
    }
    if (key !== void 0) {
      const tmp = new Uint8Array(this.blockLen);
      tmp.set(key);
      this.update(tmp);
      clean(tmp);
    }
  }
  // prettier-ignore
  get() {
    let { v0l, v0h, v1l, v1h, v2l, v2h, v3l, v3h, v4l, v4h, v5l, v5h, v6l, v6h, v7l, v7h } = this;
    return [v0l, v0h, v1l, v1h, v2l, v2h, v3l, v3h, v4l, v4h, v5l, v5h, v6l, v6h, v7l, v7h];
  }
  // prettier-ignore
  set(v0l, v0h, v1l, v1h, v2l, v2h, v3l, v3h, v4l, v4h, v5l, v5h, v6l, v6h, v7l, v7h) {
    this.v0l = v0l | 0;
    this.v0h = v0h | 0;
    this.v1l = v1l | 0;
    this.v1h = v1h | 0;
    this.v2l = v2l | 0;
    this.v2h = v2h | 0;
    this.v3l = v3l | 0;
    this.v3h = v3h | 0;
    this.v4l = v4l | 0;
    this.v4h = v4h | 0;
    this.v5l = v5l | 0;
    this.v5h = v5h | 0;
    this.v6l = v6l | 0;
    this.v6h = v6h | 0;
    this.v7l = v7l | 0;
    this.v7h = v7h | 0;
  }
  compress(msg, offset, isLast) {
    const { v0l, v0h, v1l, v1h, v2l, v2h, v3l, v3h, v4l, v4h, v5l, v5h, v6l, v6h, v7l, v7h } = this;
    {
      BBUF[0] = v0l;
      BBUF[1] = v0h;
      BBUF[2] = v1l;
      BBUF[3] = v1h;
      BBUF[4] = v2l;
      BBUF[5] = v2h;
      BBUF[6] = v3l;
      BBUF[7] = v3h;
      BBUF[8] = v4l;
      BBUF[9] = v4h;
      BBUF[10] = v5l;
      BBUF[11] = v5h;
      BBUF[12] = v6l;
      BBUF[13] = v6h;
      BBUF[14] = v7l;
      BBUF[15] = v7h;
    }
    BBUF.set(B2B_IV, 16);
    const l = fromNumL(this.length);
    const h = fromNumH(this.length);
    BBUF[24] = B2B_IV[8] ^ l;
    BBUF[25] = B2B_IV[9] ^ h;
    if (isLast) {
      BBUF[28] = ~BBUF[28];
      BBUF[29] = ~BBUF[29];
    }
    let j = 0;
    const s = BSIGMA;
    for (let i = 0; i < 12; i++) {
      G1b(0, 4, 8, 12, msg, offset + 2 * s[j++]);
      G2b(0, 4, 8, 12, msg, offset + 2 * s[j++]);
      G1b(1, 5, 9, 13, msg, offset + 2 * s[j++]);
      G2b(1, 5, 9, 13, msg, offset + 2 * s[j++]);
      G1b(2, 6, 10, 14, msg, offset + 2 * s[j++]);
      G2b(2, 6, 10, 14, msg, offset + 2 * s[j++]);
      G1b(3, 7, 11, 15, msg, offset + 2 * s[j++]);
      G2b(3, 7, 11, 15, msg, offset + 2 * s[j++]);
      G1b(0, 5, 10, 15, msg, offset + 2 * s[j++]);
      G2b(0, 5, 10, 15, msg, offset + 2 * s[j++]);
      G1b(1, 6, 11, 12, msg, offset + 2 * s[j++]);
      G2b(1, 6, 11, 12, msg, offset + 2 * s[j++]);
      G1b(2, 7, 8, 13, msg, offset + 2 * s[j++]);
      G2b(2, 7, 8, 13, msg, offset + 2 * s[j++]);
      G1b(3, 4, 9, 14, msg, offset + 2 * s[j++]);
      G2b(3, 4, 9, 14, msg, offset + 2 * s[j++]);
    }
    this.v0l ^= BBUF[0] ^ BBUF[16];
    this.v0h ^= BBUF[1] ^ BBUF[17];
    this.v1l ^= BBUF[2] ^ BBUF[18];
    this.v1h ^= BBUF[3] ^ BBUF[19];
    this.v2l ^= BBUF[4] ^ BBUF[20];
    this.v2h ^= BBUF[5] ^ BBUF[21];
    this.v3l ^= BBUF[6] ^ BBUF[22];
    this.v3h ^= BBUF[7] ^ BBUF[23];
    this.v4l ^= BBUF[8] ^ BBUF[24];
    this.v4h ^= BBUF[9] ^ BBUF[25];
    this.v5l ^= BBUF[10] ^ BBUF[26];
    this.v5h ^= BBUF[11] ^ BBUF[27];
    this.v6l ^= BBUF[12] ^ BBUF[28];
    this.v6h ^= BBUF[13] ^ BBUF[29];
    this.v7l ^= BBUF[14] ^ BBUF[30];
    this.v7h ^= BBUF[15] ^ BBUF[31];
    clean(BBUF);
  }
  destroy() {
    this.destroyed = true;
    clean(this.buffer32);
    this.set(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  }
};
var blake2b = /* @__PURE__ */ createHasher((opts) => new _BLAKE2b(opts));
function _compress(s, offset, msg, rounds, v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15) {
  let j = 0;
  for (let i = 0; i < rounds; i++) {
    ({ a: v0, b: v4, c: v8, d: v12 } = G1s(v0, v4, v8, v12, msg[offset + s[j++]]));
    ({ a: v0, b: v4, c: v8, d: v12 } = G2s(v0, v4, v8, v12, msg[offset + s[j++]]));
    ({ a: v1, b: v5, c: v9, d: v13 } = G1s(v1, v5, v9, v13, msg[offset + s[j++]]));
    ({ a: v1, b: v5, c: v9, d: v13 } = G2s(v1, v5, v9, v13, msg[offset + s[j++]]));
    ({ a: v2, b: v6, c: v10, d: v14 } = G1s(v2, v6, v10, v14, msg[offset + s[j++]]));
    ({ a: v2, b: v6, c: v10, d: v14 } = G2s(v2, v6, v10, v14, msg[offset + s[j++]]));
    ({ a: v3, b: v7, c: v11, d: v15 } = G1s(v3, v7, v11, v15, msg[offset + s[j++]]));
    ({ a: v3, b: v7, c: v11, d: v15 } = G2s(v3, v7, v11, v15, msg[offset + s[j++]]));
    ({ a: v0, b: v5, c: v10, d: v15 } = G1s(v0, v5, v10, v15, msg[offset + s[j++]]));
    ({ a: v0, b: v5, c: v10, d: v15 } = G2s(v0, v5, v10, v15, msg[offset + s[j++]]));
    ({ a: v1, b: v6, c: v11, d: v12 } = G1s(v1, v6, v11, v12, msg[offset + s[j++]]));
    ({ a: v1, b: v6, c: v11, d: v12 } = G2s(v1, v6, v11, v12, msg[offset + s[j++]]));
    ({ a: v2, b: v7, c: v8, d: v13 } = G1s(v2, v7, v8, v13, msg[offset + s[j++]]));
    ({ a: v2, b: v7, c: v8, d: v13 } = G2s(v2, v7, v8, v13, msg[offset + s[j++]]));
    ({ a: v3, b: v4, c: v9, d: v14 } = G1s(v3, v4, v9, v14, msg[offset + s[j++]]));
    ({ a: v3, b: v4, c: v9, d: v14 } = G2s(v3, v4, v9, v14, msg[offset + s[j++]]));
  }
  return { v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15 };
}

// ../../../kusdt-open/bridge/packages/kaspa/src/tx.ts
var NATIVE_SUBNET = new Uint8Array(20);
var STORAGE_MASS_PARAMETER = 10n ** 12n;
var enc = new TextEncoder();
var KEY_SIGNING = enc.encode("TransactionSigningHash");
var KEY_TXID = enc.encode("TransactionID");
var ZERO_HASH = new Uint8Array(32);

// node_modules/@noble/hashes/blake3.js
init_md();
init_u64();
init_utils();
var B3_Flags = {
  CHUNK_START: 1,
  CHUNK_END: 2,
  PARENT: 4,
  ROOT: 8,
  KEYED_HASH: 16,
  DERIVE_KEY_CONTEXT: 32,
  DERIVE_KEY_MATERIAL: 64
};
var B3_IV = /* @__PURE__ */ SHA256_IV.slice();
var B3_SIGMA = /* @__PURE__ */ (() => {
  const Id = Array.from({ length: 16 }, (_, i) => i);
  const permute = (arr) => [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8].map((i) => arr[i]);
  const res = [];
  for (let i = 0, v = Id; i < 7; i++, v = permute(v))
    res.push(...v);
  return Uint8Array.from(res);
})();
var _BLAKE3 = class __BLAKE3 extends _BLAKE2 {
  canXOF = true;
  chunkPos = 0;
  // Position of current block in chunk
  // How many chunks we already have; exact while this stays within
  // JS's safe-integer range.
  chunksDone = 0;
  flags = 0 | 0;
  IV;
  state;
  stack = [];
  // Output
  posOut = 0;
  bufferOut32 = new Uint32Array(16);
  bufferOut;
  // Index of output chunk; exact while this stays within JS's
  // safe-integer range.
  chunkOut = 0;
  enableXOF = true;
  constructor(opts = {}, flags = 0) {
    opts = checkOpts({}, opts);
    super(64, opts.dkLen === void 0 ? 32 : opts.dkLen);
    const { key, context } = opts;
    const hasContext = context !== void 0;
    if (key !== void 0) {
      if (hasContext)
        throw new Error('cannot use both "key" and "context"');
      abytes(key, 32, "key");
      const k = copyBytes(key);
      this.IV = u32(k);
      swap32IfBE(this.IV);
      this.flags = flags | B3_Flags.KEYED_HASH;
    } else if (hasContext) {
      abytes(context, void 0, "context");
      const ctx = context;
      const contextKey = new __BLAKE3({ dkLen: 32 }, B3_Flags.DERIVE_KEY_CONTEXT).update(ctx).digest();
      this.IV = u32(contextKey);
      swap32IfBE(this.IV);
      this.flags = flags | B3_Flags.DERIVE_KEY_MATERIAL;
    } else {
      this.IV = B3_IV;
      this.flags = flags;
    }
    this.state = this.IV.slice();
    this.bufferOut = u8(this.bufferOut32);
  }
  // _BLAKE2's scalar-state hooks are unused here: BLAKE3 keeps its tree/XOF state in arrays and
  // copies it directly in _cloneInto().
  get() {
    return [];
  }
  set() {
  }
  // Truncated chunk/parent compression: seed v8..v15 as IV[0..3], t0, t1,
  // block length, and flags, then keep only the first 8 output words.
  b2Compress(counter, flags, buf, bufPos = 0) {
    const { state: s, pos } = this;
    const t0 = fromNumL(counter);
    const t1 = fromNumH(counter);
    const { v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15 } = _compress(B3_SIGMA, bufPos, buf, 7, s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], B3_IV[0], B3_IV[1], B3_IV[2], B3_IV[3], t0, t1, pos, flags);
    s[0] = v0 ^ v8;
    s[1] = v1 ^ v9;
    s[2] = v2 ^ v10;
    s[3] = v3 ^ v11;
    s[4] = v4 ^ v12;
    s[5] = v5 ^ v13;
    s[6] = v6 ^ v14;
    s[7] = v7 ^ v15;
  }
  compress(buf, bufPos = 0, isLast = false) {
    let flags = this.flags;
    if (!this.chunkPos)
      flags |= B3_Flags.CHUNK_START;
    if (this.chunkPos === 15 || isLast)
      flags |= B3_Flags.CHUNK_END;
    if (!isLast)
      this.pos = this.blockLen;
    this.b2Compress(this.chunksDone, flags, buf, bufPos);
    this.chunkPos += 1;
    if (this.chunkPos === 16 || isLast) {
      let chunk = this.state;
      this.state = this.IV.slice();
      for (let last, chunks = this.chunksDone + 1; isLast || !(chunks & 1); chunks = Math.floor(chunks / 2)) {
        if (!(last = this.stack.pop()))
          break;
        this.buffer32.set(last, 0);
        this.buffer32.set(chunk, 8);
        this.pos = this.blockLen;
        this.b2Compress(0, this.flags | B3_Flags.PARENT, this.buffer32, 0);
        chunk = this.state;
        this.state = this.IV.slice();
      }
      this.chunksDone++;
      this.chunkPos = 0;
      this.stack.push(chunk);
    }
    this.pos = 0;
  }
  // Overriding hides _BLAKE2's flat implementation, which would otherwise be inherited
  // and silently miss the tree state (CV stack, chunk counters; get()/set() are stubs here).
  _cloneInto(to) {
    const staleOutput = !!to && to.finished && !to.destroyed;
    to = super._cloneInto(to);
    const { IV, flags, state, chunkPos, posOut, chunkOut, stack, chunksDone } = this;
    to.state.set(state);
    to.stack = stack.map((i) => Uint32Array.from(i));
    if (IV === B3_IV) {
      if (to.IV !== B3_IV)
        clean(to.IV);
      to.IV = B3_IV;
    } else if (to.IV === B3_IV) {
      to.IV = IV.slice();
    } else {
      to.IV.set(IV);
    }
    to.flags = flags;
    to.chunkPos = chunkPos;
    to.chunksDone = chunksDone;
    to.posOut = posOut;
    to.chunkOut = chunkOut;
    to.enableXOF = this.enableXOF;
    if (this.finished) {
      to.bufferOut32.set(this.bufferOut32);
    } else if (staleOutput) {
      clean(to.bufferOut32);
    }
    return to;
  }
  destroy() {
    this.destroyed = true;
    clean(this.state, this.buffer32, this.bufferOut32);
    if (this.IV !== B3_IV)
      clean(this.IV);
    clean(...this.stack);
  }
  // Root/XOF compression: rerun the same ROOT inputs with incrementing output
  // counter `t` and materialize all 16 output words.
  // Same as b2Compress, but doesn't modify state and returns 16 u32 array (instead of 8)
  b2CompressOut() {
    const { state: s, pos, flags, buffer32, bufferOut32: out32 } = this;
    const outCounter = this.chunkOut++;
    const t0 = fromNumL(outCounter);
    const t1 = fromNumH(outCounter);
    swap32IfBE(buffer32);
    const { v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15 } = _compress(B3_SIGMA, 0, buffer32, 7, s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], B3_IV[0], B3_IV[1], B3_IV[2], B3_IV[3], t0, t1, pos, flags);
    out32[0] = v0 ^ v8;
    out32[1] = v1 ^ v9;
    out32[2] = v2 ^ v10;
    out32[3] = v3 ^ v11;
    out32[4] = v4 ^ v12;
    out32[5] = v5 ^ v13;
    out32[6] = v6 ^ v14;
    out32[7] = v7 ^ v15;
    out32[8] = s[0] ^ v8;
    out32[9] = s[1] ^ v9;
    out32[10] = s[2] ^ v10;
    out32[11] = s[3] ^ v11;
    out32[12] = s[4] ^ v12;
    out32[13] = s[5] ^ v13;
    out32[14] = s[6] ^ v14;
    out32[15] = s[7] ^ v15;
    swap32IfBE(buffer32);
    swap32IfBE(out32);
    this.posOut = 0;
  }
  finish() {
    if (this.finished)
      return;
    this.finished = true;
    this.buffer.fill(0, this.pos);
    let flags = this.flags | B3_Flags.ROOT;
    if (this.stack.length) {
      flags |= B3_Flags.PARENT;
      swap32IfBE(this.buffer32);
      this.compress(this.buffer32, 0, true);
      swap32IfBE(this.buffer32);
      this.chunksDone = 0;
      this.pos = this.blockLen;
    } else {
      flags |= (!this.chunkPos ? B3_Flags.CHUNK_START : 0) | B3_Flags.CHUNK_END;
    }
    this.flags = flags;
    this.b2CompressOut();
  }
  writeInto(out) {
    aexists(this, false);
    abytes(out);
    this.finish();
    const { blockLen, bufferOut } = this;
    for (let pos = 0, len = out.length; pos < len; ) {
      if (this.posOut >= blockLen)
        this.b2CompressOut();
      const take = Math.min(blockLen - this.posOut, len - pos);
      out.set(bufferOut.subarray(this.posOut, this.posOut + take), pos);
      this.posOut += take;
      pos += take;
    }
    return out;
  }
  xofInto(out) {
    if (!this.enableXOF)
      throw new Error("no XOF after digest()");
    return this.writeInto(out);
  }
  xof(bytes) {
    anumber(bytes);
    return this.xofInto(new Uint8Array(bytes));
  }
  digestInto(out) {
    aoutput(out, this);
    if (this.finished)
      throw new Error("digest() was already called");
    this.enableXOF = false;
    this.writeInto(out.length === this.outputLen ? out : out.subarray(0, this.outputLen));
    this.destroy();
  }
  digest() {
    const out = new Uint8Array(this.outputLen);
    this.digestInto(out);
    return out;
  }
};
var blake3 = /* @__PURE__ */ createHasher((opts = {}) => new _BLAKE3(opts));

// ../../../kusdt-open/bridge/packages/kaspa/src/txid.ts
var U64_MAX = (1n << 64n) - 1n;
function u64(v) {
  const b = typeof v === "bigint" ? v : typeof v === "number" && Number.isSafeInteger(v) ? BigInt(v) : typeof v === "string" && /^\d{1,20}$/.test(v) ? BigInt(v) : null;
  return b !== null && b >= 0n && b <= U64_MAX ? b : null;
}
var uint = (v, max) => {
  const n = typeof v === "string" && /^\d{1,10}$/.test(v) ? Number(v) : v;
  return typeof n === "number" && Number.isInteger(n) && n >= 0 && n <= max ? n : null;
};
var present = (x) => x !== null;
var hexOf = (v, chars) => typeof v === "string" && /^(?:[0-9a-fA-F]{2})*$/.test(v) && (chars === void 0 || v.length === chars) ? v.toLowerCase() : null;
function scriptOf(v) {
  if (typeof v === "string") return v.length >= 4 ? hexOf(v) : null;
  const o = v;
  const version = uint(o?.version, 65535), script = hexOf(o?.scriptPublicKey);
  return version === null || script === null ? null : version.toString(16).padStart(4, "0") + script;
}
function idBodyOf(v) {
  const b = v;
  if (!b || typeof b !== "object" || !Array.isArray(b.inputs) || !Array.isArray(b.outputs)) return null;
  const inputs = b.inputs.map((i) => {
    const transactionId2 = hexOf(i?.previousOutpoint?.transactionId, 64), index = uint(i?.previousOutpoint?.index, 4294967295), sequence = u64(i?.sequence);
    return transactionId2 === null || index === null || sequence === null ? null : { transactionId: transactionId2, index, sequence };
  });
  const outputs = b.outputs.map((o) => {
    const value = u64(o?.value), scriptPublicKey = scriptOf(o?.scriptPublicKey);
    if (value === null || scriptPublicKey === null) return null;
    if (o.covenant == null) return { value, scriptPublicKey, covenant: null };
    const authorizingInput = uint(o.covenant.authorizingInput, 65535), covenantId = hexOf(o.covenant.covenantId, 64);
    return authorizingInput === null || covenantId === null ? null : { value, scriptPublicKey, covenant: { authorizingInput, covenantId } };
  });
  const version = uint(b.version, 65535), lockTime = u64(b.lockTime), gas = u64(b.gas), subnetworkId = hexOf(b.subnetworkId, 40);
  const payload = b.payload === void 0 ? null : hexOf(b.payload);
  const payloadCommitment = version === null ? null : b.payload === void 0 ? version >= 1 ? hexOf(b.payloadDigest, 64) : null : payload === null ? null : version === 0 ? payload : payloadDigestOf(payload);
  if (version === null || lockTime === null || gas === null || subnetworkId === null || payloadCommitment === null || !inputs.every(present) || !outputs.every(present)) return null;
  return { version, inputs, outputs, lockTime, subnetworkId, gas, payloadCommitment };
}
var Writer = class {
  parts = [];
  bytes(b) {
    this.parts.push(b);
    return this;
  }
  le(v, n) {
    const b = new Uint8Array(n);
    for (let i = 0; i < n; i++) b[i] = Number(v >> BigInt(8 * i) & 0xffn);
    return this.bytes(b);
  }
  u8(v) {
    return this.le(BigInt(v), 1);
  }
  u16(v) {
    return this.le(BigInt(v), 2);
  }
  u32(v) {
    return this.le(BigInt(v), 4);
  }
  u64(v) {
    return this.le(v, 8);
  }
  out() {
    return concatBytes(...this.parts);
  }
};
var utf8 = (s) => new TextEncoder().encode(s);
var key32 = (domain) => {
  const k = new Uint8Array(32);
  k.set(utf8(domain));
  return k;
};
var payloadDigestOf = (payloadHex) => bytesToHex(blake3(hexToBytes(payloadHex), { key: key32("PayloadDigest") }));
function transactionIdOf(t) {
  const w = new Writer().u16(t.version).u64(BigInt(t.inputs.length));
  for (const i of t.inputs) w.bytes(hexToBytes(i.transactionId)).u32(i.index).u64(0n).u64(i.sequence);
  w.u64(BigInt(t.outputs.length));
  for (const o of t.outputs) {
    const spk = hexToBytes(o.scriptPublicKey);
    w.u64(o.value).u16(spk[0] << 8 | spk[1]).u64(BigInt(spk.length - 2)).bytes(spk.subarray(2));
    if (t.version >= 1) {
      w.u8(o.covenant ? 1 : 0);
      if (o.covenant) w.u16(o.covenant.authorizingInput).bytes(hexToBytes(o.covenant.covenantId));
    }
  }
  w.u64(t.lockTime).bytes(hexToBytes(t.subnetworkId)).u64(t.gas);
  const payload = hexToBytes(t.payloadCommitment);
  if (t.version === 0) return bytesToHex(blake2b(w.u64(BigInt(payload.length)).bytes(payload).out(), { dkLen: 32, key: utf8("TransactionID") }));
  const rest = blake3(w.u64(0n).out(), { key: key32("TransactionRest") });
  return bytesToHex(blake3(concatBytes(payload, rest), { key: key32("TransactionV1Id") }));
}

// ../../../kusdt-open/bridge/packages/kaspa/src/build.ts
var COINBASE_MATURITY = 1100n;
function spendableUtxos(utxos, opts) {
  return utxos.filter((u) => {
    if (opts.pending?.has(`${u.txid}:${u.index}`)) return false;
    if (u.isCoinbase) return opts.virtualDaaScore != null && u.blockDaaScore + COINBASE_MATURITY <= opts.virtualDaaScore;
    return true;
  });
}

// ../../../kusdt-open/bridge/packages/kaspa/src/exactJson.ts
var MAX_INTEGER_DIGITS2 = 78;
function exactInteger2(token) {
  const m = /^(-?)(0|[1-9]\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(token);
  if (!m) return null;
  const digits = m[2] + (m[3] ?? "");
  const point = m[2].length + (m[4] ? Number(m[4]) : 0);
  const first = digits.search(/[1-9]/);
  if (first < 0) return null;
  if (digits.slice(Math.max(point, 0)).search(/[1-9]/) >= 0) return null;
  const count = point - first;
  if (count < 16) return null;
  if (count > MAX_INTEGER_DIGITS2) return token;
  return m[1] + digits.slice(first, point).padEnd(count, "0");
}
function quoteLargeIntegers2(text) {
  let out = "";
  let copied = 0;
  let i = 0;
  while (i < text.length) {
    const c = text.charCodeAt(i);
    if (c === 34) {
      i++;
      while (i < text.length && text.charCodeAt(i) !== 34) i += text.charCodeAt(i) === 92 ? 2 : 1;
      i++;
    } else if (c === 45 || c >= 48 && c <= 57) {
      const start = i;
      i++;
      for (; i < text.length; i++) {
        const d = text.charCodeAt(i);
        if (!(d >= 48 && d <= 57 || d === 46 || d === 101 || d === 69 || d === 43 || d === 45)) break;
      }
      const exact = exactInteger2(text.slice(start, i));
      if (exact !== null) {
        out += text.slice(copied, start) + '"' + exact + '"';
        copied = i;
      }
    } else i++;
  }
  return copied === 0 ? text : out + text.slice(copied);
}
function parseExactJson2(text) {
  return JSON.parse(quoteLargeIntegers2(text));
}

// ../../../kusdt-open/bridge/packages/kaspa/src/rpc.ts
function nodeHasTransaction(message, txid) {
  const id = txid.toLowerCase(), said = message.toLowerCase();
  return said.includes(`transaction ${id} is already in the mempool`) || said.includes(`transaction ${id} was already accepted`);
}
var MAX_MESSAGE_CHARS = 64e6;
var UNPARSED_FROM = 1e6;
var OPEN = 1;
var RpcError = class extends Error {
  constructor(method, message) {
    super(`${method}: ${message}`);
    this.method = method;
  }
  method;
};
var RpcTooLargeError = class extends RpcError {
  constructor(method, chars, limit) {
    super(method, chars === null ? `the node's answer is over ${limit ? `the limit of ${limit} bytes` : "the socket's own limit"}: refused at its first bytes, unread, and the connection it came on was dropped` : `the node's answer is ${chars} characters, over the limit of ${limit}: refused unread`);
    this.chars = chars;
    this.limit = limit;
  }
  chars;
  limit;
};
function refusedForSize(event) {
  return event?.code === 1009 || event?.error?.code === "WS_ERR_UNSUPPORTED_MESSAGE_LENGTH";
}
function nodeHost(url) {
  const m = /^([a-z][a-z0-9+.-]*:\/\/)(?:[^/?#]*@)?([^/?#]*)/i.exec(String(url));
  return m ? m[1] + m[2] : "the address it was given";
}
var KaspaRpc = class {
  constructor(url, timeoutMs = 2e4, options = {}) {
    this.url = url;
    this.timeoutMs = timeoutMs;
    this.options = options;
  }
  url;
  timeoutMs;
  options;
  ws = null;
  id = 0;
  pending = /* @__PURE__ */ new Map();
  listeners = /* @__PURE__ */ new Map();
  opening = null;
  timeouts = 0;
  closed = false;
  /** How many times the client reconnected on its own (for logs and tests). */
  reconnects = 0;
  /** How many times the socket refused a message for its size, and the connection was dropped for it. */
  refusals = 0;
  /** How many long answers came for calls nobody waited for any more (one that timed out), and were dropped unparsed. */
  lateDropped = 0;
  /**
   * When the node last sent anything on this client's connections (ms): an answer, an error answer or a notification.
   * A monitor tells a node it cannot reach from one that answers (round 30): none of it says the answers are right.
   */
  heardAt;
  refusedSockets = /* @__PURE__ */ new WeakSet();
  async connect() {
    this.closed = false;
    await this.open();
    return this;
  }
  /** Opens a socket (one at a time); the previous one, if any, is already dropped. */
  open() {
    if (this.opening) return this.opening;
    this.opening = (async () => {
      const ws = this.options.socket ? this.options.socket(this.url) : new WebSocket(this.url);
      await new Promise((ok, fail) => {
        ws.onopen = () => ok();
        ws.onerror = () => fail(new Error(`cannot reach the Kaspa node at ${nodeHost(this.url)}`));
      });
      ws.onerror = (event) => {
        if (refusedForSize(event)) this.refused(ws);
      };
      ws.onmessage = (event) => this.receive(String(event.data));
      ws.onclose = (event) => {
        if (refusedForSize(event)) this.refused(ws);
        for (const [id, p] of this.pending) {
          if (p.ws !== ws) continue;
          clearTimeout(p.timer);
          this.pending.delete(id);
          p.fail(new Error("the Kaspa node closed the connection"));
        }
        if (this.ws === ws) this.ws = null;
      };
      this.ws = ws;
      this.timeouts = 0;
    })().finally(() => {
      this.opening = null;
    });
    return this.opening;
  }
  /**
   * The socket refused a message for its size, at the frame header: nothing of it was kept. Which call it answered is
   * not known (the id is in the message). With one call waiting on this socket it is that call's, and it is told so by
   * name (RpcTooLargeError), as when a message is refused after it arrived. With several, none is told it was its own:
   * each fails as on a closed connection, and a caller that must know asks alone (shared/kaspa.ts does, for address
   * reads). The connection is dropped at once: the node is still sending the message, and a socket left to close
   * politely would go on receiving it. The next call opens a new one (with `reconnect`).
   */
  refused(ws) {
    if (this.refusedSockets.has(ws)) return;
    this.refusedSockets.add(ws);
    const waiting = [...this.pending].filter(([, p]) => p.ws === ws);
    const limit = this.options.maxFrameBytes ?? 0;
    for (const [id, p] of waiting) {
      clearTimeout(p.timer);
      this.pending.delete(id);
      p.fail(waiting.length === 1 ? new RpcTooLargeError(p.method, null, limit) : new RpcError(p.method, `the connection was dropped: the node sent a message over ${limit ? `the limit of ${limit} bytes` : "the socket's own limit"}, this call's answer or another's`));
    }
    if (this.ws === ws) this.ws = null;
    this.refusals++;
    try {
      if (ws.terminate) ws.terminate();
      else ws.close();
    } catch {
    }
  }
  /** The open socket; with `reconnect`, a new one when the last closed or went silent. */
  async socket() {
    if (this.ws && this.ws.readyState === OPEN) return this.ws;
    if (!this.options.reconnect || this.closed) throw new Error("not connected");
    if (this.ws) {
      try {
        this.ws.close();
      } catch {
      }
      this.ws = null;
    }
    await this.open();
    this.reconnects++;
    return this.ws;
  }
  /** A call timed out: after `deadAfter` in a row, the socket counts as dead and the next call reconnects. */
  timedOut(ws) {
    if (++this.timeouts < (this.options.deadAfter ?? 2) || !this.options.reconnect || this.ws !== ws) return;
    this.ws = null;
    try {
      if (ws.terminate) ws.terminate();
      else ws.close();
    } catch {
    }
  }
  send(raw, method, params, unparsedUpTo) {
    return this.socket().then((ws) => {
      const id = ++this.id;
      const body = typeof params === "string" ? params : JSON.stringify(params);
      ws.send(`{"id":${id},"method":"${method}","params":${body}}`);
      return new Promise((ok, fail) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          this.timedOut(ws);
          fail(new RpcError(method, "timed out"));
        }, this.timeoutMs);
        this.pending.set(id, { ok, fail, timer, raw, ws, method, unparsedUpTo });
      });
    });
  }
  receive(text) {
    this.heardAt = Date.now();
    const limit = this.options.maxMessageChars ?? MAX_MESSAGE_CHARS;
    if (text.length > limit || text.length > UNPARSED_FROM) {
      const id = /^\s*\{\s*"id"\s*:\s*(\d{1,15})\s*[,}]/.exec(text.slice(0, 64)) ?? /,\s*"id"\s*:\s*(\d{1,15})\s*\}\s*$/.exec(text.slice(-64));
      const p = id ? this.pending.get(Number(id[1])) : void 0;
      const unparsed = p?.raw && p.unparsedUpTo !== void 0 ? p.unparsedUpTo : void 0;
      if (id && !p) {
        this.lateDropped++;
        return;
      }
      if (text.length > limit && !p) return;
      if (id && p && (unparsed !== void 0 || text.length > limit)) {
        this.pending.delete(Number(id[1]));
        clearTimeout(p.timer);
        this.timeouts = 0;
        if (unparsed !== void 0 && text.length <= unparsed) p.ok(text);
        else p.fail(new RpcTooLargeError(p.method, text.length, unparsed ?? limit));
        return;
      }
    }
    let msg;
    try {
      msg = parseExactJson2(text);
    } catch {
      this.ws?.close();
      return;
    }
    if (!msg || typeof msg !== "object") {
      this.ws?.close();
      return;
    }
    if (msg.id != null && this.pending.has(msg.id)) {
      const p = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      this.timeouts = 0;
      if (p.raw && !msg.error) {
        p.ok(text);
        return;
      }
      if (msg.error) p.fail(new RpcError(String(msg.method ?? "call"), typeof msg.error === "string" ? msg.error : msg.error.message ?? JSON.stringify(msg.error)));
      else p.ok(msg.params);
      return;
    }
    if (msg.id != null) return;
    if (msg.method) for (const l of this.listeners.get(msg.method) ?? []) l(msg.params);
  }
  /** `params` is either an object or a raw JSON string (for exact big integers). */
  call(method, params = {}) {
    return this.send(false, method, params);
  }
  /**
   * Like `call`, but answers the whole raw message text (to pass node data back untouched). With `unparsedUpTo`, a
   * long answer (over UNPARSED_FROM, or over the message limit) of up to that length is handed back unparsed and
   * unchecked, and a longer one is refused: for a caller that reads it in parts (jsonArrayItems) and so never holds
   * it parsed. The message limit does not apply to such a read; `unparsedUpTo` is its limit.
   */
  callRaw(method, params = {}, opts = {}) {
    return this.send(true, method, params, opts.unparsedUpTo);
  }
  /** Listen for a notification method (e.g. "blockAddedNotification"). */
  on(method, listener) {
    const set = this.listeners.get(method) ?? /* @__PURE__ */ new Set();
    set.add(listener);
    this.listeners.set(method, set);
    return () => set.delete(listener);
  }
  /** Closes the socket for good: no call reconnects it (connect() again does). */
  close() {
    this.closed = true;
    this.ws?.close();
    this.ws = null;
  }
};
function rawJsonObject(text, key) {
  const at = text.indexOf(`"${key}":{`);
  if (at < 0) throw new Error(`no "${key}" object in the message`);
  let depth = 0, inString = false;
  for (let i = at + key.length + 3; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return text.slice(at + key.length + 3, i + 1);
  }
  throw new Error(`unterminated "${key}" object`);
}

// ../../../kusdt-open/bridge/packages/kaspa/src/minable.ts
var SEQUENCE_LOCK_DISABLED = 1n << 63n;
var SEQUENCE_LOCK_MASK = 0xffffffffn;
var MINABLE_MAX_LOOKUPS = 64;
var MINABLE_MAX_DEPTH = 32;
var MINABLE_MAX_AGE_ASKS = 4;
function relativeLock(sequence) {
  let s;
  try {
    if (typeof sequence === "bigint") s = sequence;
    else if (typeof sequence === "number" && Number.isSafeInteger(sequence)) s = BigInt(sequence);
    else if (typeof sequence === "string" && /^\d{1,20}$/.test(sequence)) s = BigInt(sequence);
    else return null;
  } catch {
    return null;
  }
  if (s < 0n || s >= 1n << 64n) return null;
  if ((s & SEQUENCE_LOCK_DISABLED) !== 0n) return 0n;
  return s & SEQUENCE_LOCK_MASK;
}
var outpointOf = (input) => {
  const o = input?.previousOutpoint;
  const index = Number(o?.index);
  return typeof o?.transactionId === "string" && /^[0-9a-f]{64}$/.test(o.transactionId) && Number.isInteger(index) && index >= 0 ? { transactionId: o.transactionId, index } : null;
};
async function minability(txid, tx, reads, opts = {}) {
  const known = opts.known ?? /* @__PURE__ */ new Map();
  const maxLookups = opts.maxLookups ?? MINABLE_MAX_LOOKUPS;
  const maxDepth = opts.maxDepth ?? MINABLE_MAX_DEPTH;
  const maxAgeAsks = opts.maxAgeAsks ?? MINABLE_MAX_AGE_ASKS;
  const parents = /* @__PURE__ */ new Map();
  let lookups = 0;
  const ages = /* @__PURE__ */ new Map();
  let virtual;
  const inProgress = /* @__PURE__ */ new Set();
  const judge = async (id, body, depth) => {
    const before = known.get(id);
    if (before) return before;
    const no = (why, at = id) => ({ minable: false, txid: at, why });
    if (inProgress.has(id)) return no("its unconfirmed ancestors form a cycle");
    if (depth > maxDepth) return no(`it has more than ${maxDepth} levels of unconfirmed ancestors: not checked further`);
    if (!Array.isArray(body?.inputs) || body.inputs.length === 0) return no("its inputs can't be read");
    const inputs = [];
    for (const [n, input] of body.inputs.entries()) {
      const spent = outpointOf(input);
      const lock = relativeLock(input?.sequence);
      if (!spent || lock === null) return no(`input ${n} can't be read`);
      inputs.push({ n, spent, lock });
    }
    const locked = inputs.filter((i) => i.lock > 0n);
    if (locked.length > maxAgeAsks) return no(`it claims an age for ${locked.length} of the outputs it spends: more than ${maxAgeAsks}, which no honest spend does, so none is looked up`);
    inProgress.add(id);
    try {
      let unvouched = null;
      for (const { n, spent, lock } of [...locked, ...inputs.filter((i) => i.lock === 0n)]) {
        if (lock === 0n && unvouched) return unvouched;
        let parent = parents.get(spent.transactionId);
        if (parent === void 0) {
          if (++lookups > maxLookups) return no(`it has more than ${maxLookups} inputs or unconfirmed ancestors to look up: not checked further`);
          parent = await reads.mempoolTransaction(spent.transactionId);
          parents.set(spent.transactionId, parent ?? null);
        }
        if (parent) {
          if (lock > 0n) return no(`input ${n} claims an age of ${lock} DAA for an output of ${spent.transactionId}, which is still in the mempool: an unconfirmed output has no age`);
          const above = await judge(spent.transactionId, parent, depth + 1);
          if (!above.minable) return above.txid === spent.transactionId ? { ...no(`it spends an output of ${spent.transactionId}, which no block can take (${above.why})`, above.txid), ...above.unknown && { unknown: true } } : above;
          continue;
        }
        if (lock === 0n) continue;
        const key = `${spent.transactionId}:${spent.index}`;
        let accepted = ages.get(key);
        if (accepted === void 0) {
          if (ages.size >= maxAgeAsks) return no(`it and its unconfirmed ancestors claim an age for more than ${maxAgeAsks} outputs: not checked further`);
          accepted = await reads.acceptedDaa(spent);
          ages.set(key, accepted);
        }
        if (accepted === null) {
          unvouched ??= { ...no(`input ${n} claims an age of ${lock} DAA for ${spent.transactionId}:${spent.index}, and the node can't say when that output was accepted`), unknown: true };
          continue;
        }
        virtual ??= await reads.virtualDaa();
        if (accepted + lock - 1n >= virtual) return no(`input ${n} claims an age of ${lock} DAA for an output accepted at DAA ${accepted}: no block takes it before DAA ${accepted + lock} (now ${virtual})`);
      }
      return unvouched ?? { minable: true };
    } finally {
      inProgress.delete(id);
    }
  };
  const verdict = await judge(txid, tx, 0);
  known.set(txid, verdict);
  return verdict;
}
var MINABLE_KEPT_MS = 5e3;
var UNMINABLE_KEPT_MS = 6e5;
var VerdictMemory = class {
  constructor(most = 256, now = Date.now) {
    this.most = most;
    this.now = now;
  }
  most;
  now;
  kept = /* @__PURE__ */ new Map();
  get(txid) {
    const k = this.kept.get(txid);
    if (!k) return void 0;
    const now = this.now();
    if (now - k.at > (k.verdict.minable ? MINABLE_KEPT_MS : UNMINABLE_KEPT_MS)) {
      this.kept.delete(txid);
      return void 0;
    }
    if (!k.verdict.minable) k.at = now;
    return k.verdict;
  }
  set(txid, verdict) {
    this.kept.delete(txid);
    if (!verdict.minable && verdict.unknown) return;
    this.kept.set(txid, { verdict, at: this.now() });
    while (this.kept.size > this.most) this.kept.delete(this.kept.keys().next().value);
  }
  /** `minability`, answered from what is kept when it can be. A check that throws keeps nothing. */
  async judge(txid, tx, reads, opts = {}) {
    const before = this.get(txid);
    if (before) {
      opts.known?.set(txid, before);
      return before;
    }
    const verdict = await minability(txid, tx, reads, opts);
    this.set(txid, verdict);
    return verdict;
  }
};
function isNodeRefusal(e) {
  return e instanceof RpcError && !(e instanceof RpcTooLargeError) && !/timed out$/.test(e.message);
}
function nodeMinableReads(call, acceptedAt) {
  return {
    virtualDaa: async () => BigInt((await call("getBlockDagInfo", {})).virtualDaaScore),
    mempoolTransaction: async (txid) => {
      try {
        const answer = await call("getMempoolEntry", { transactionId: txid, includeOrphanPool: false, filterTransactionPool: false });
        const tx = answer?.mempoolEntry?.transaction;
        return tx && Array.isArray(tx.inputs) ? tx : null;
      } catch (e) {
        if (isNodeRefusal(e) && /not found/i.test(e.message)) return null;
        throw e;
      }
    },
    acceptedDaa: async (outpoint2) => acceptedAt?.(outpoint2) ?? null
  };
}
var spenderOf = (entry) => {
  const tx = entry?.transaction;
  const txid = tx?.verboseData?.transactionId;
  if (typeof txid !== "string" || !/^[0-9a-f]{64}$/.test(txid) || !Array.isArray(tx?.inputs)) return null;
  let fee = null;
  try {
    if (entry.fee !== void 0 && entry.fee !== null) fee = BigInt(String(entry.fee));
  } catch {
  }
  return { txid, tx, fee: fee !== null && fee >= 0n ? fee : null };
};
function listed(answer, key) {
  const found = /* @__PURE__ */ new Map();
  for (const entry of Array.isArray(answer?.entries) ? answer.entries : []) {
    for (const one of Array.isArray(entry?.[key]) ? entry[key] : []) {
      const s = spenderOf(one);
      if (s && !found.has(s.txid)) found.set(s.txid, s);
    }
  }
  return [...found.values()];
}
var sendingIn = (answer) => listed(answer, "sending");
var receivingIn = (answer) => listed(answer, "receiving");
function spendsOutpoint(tx, outpoint2) {
  const index = Number(outpoint2.index);
  return (Array.isArray(tx?.inputs) ? tx.inputs : []).some((i) => i?.previousOutpoint?.transactionId === outpoint2.transactionId && Number(i.previousOutpoint.index) === index);
}

// src/web-stub.ts
function loadCore() {
  throw new Error("The kUSDT core is loaded by KaPay.");
}

// src/wasm-url-stub.ts
var wasm_url_stub_default = "";

// ../../../kusdt-open/wallet/extension/src/lib/core.ts
var loader = () => loadCore(wasm_url_stub_default);
var loaded = null;
function getCore() {
  loaded ??= loader().catch((e) => {
    loaded = null;
    throw e;
  });
  return loaded;
}
function setCoreLoader(fn) {
  loader = async () => fn();
  loaded = null;
}

// ../../../kusdt-open/wallet/extension/src/config/defaults.ts
var CHAIN_CODE = { ethereum: 1, bsc: 2 };
var TO_BE_FILLED = "";
var DEFAULT_TOKEN_VALUE = "150000000";
var DEFAULT_POSITION_VALUE = "200000000";
var DEFAULT_BURN_VALUE = "30000000";
var DEFAULTS = {
  // The live public testnet: Kaspa testnet-10 with Sepolia and BSC testnet
  // (deployments/testnet.json), served at https://testnet.trestly.io; live since
  // 4 November 2026 (deploy/compose.testnet.yml). The node is any node of the
  // public Kaspa node network (the resolver reaches testnet-10).
  "testnet-10": {
    nodeUrl: "",
    apiUrl: "https://testnet.trestly.io/api/v1",
    covenantId: "a1d9fd1347128011ad0036b077949d63274d5d3b8ac8351776c30c945ef2c2fb",
    poolId: "99445008e36139d0a57040f562414e298a3022fb739c0e9374b1dbb9f4c42171",
    tokenValue: DEFAULT_TOKEN_VALUE,
    positionValue: DEFAULT_POSITION_VALUE,
    burnValue: DEFAULT_BURN_VALUE,
    chains: {
      ethereum: {
        name: "Sepolia",
        chainId: 11155111,
        gasSymbol: "ETH",
        vault: "0xeec4724B6D49f694656C1AE82D1A6eF8060f64BA",
        token: "0x73ee84cf953CDa0501Be2Ac26E4b92606eF85Fd6",
        decimals: 6,
        blocklist: "isBlackListed",
        // (sepolia.drpc.org no longer serves Sepolia on its free plan: it answers "chain is not available".)
        rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.gateway.tenderly.co"],
        explorerTx: "https://sepolia.etherscan.io/tx/{tx}"
      },
      bsc: {
        name: "BSC testnet",
        chainId: 97,
        gasSymbol: "tBNB",
        vault: "0xeB9D91915E3CC696e2fDFDEd614551a5C6bf58f4",
        token: "0x422B8b64971C1664DeCB5015c034d8094cb93EF4",
        decimals: 18,
        blocklist: null,
        rpcUrls: ["https://bsc-testnet-rpc.publicnode.com", "https://data-seed-prebsc-1-s1.bnbchain.org:8545"],
        explorerTx: "https://testnet.bscscan.com/tx/{tx}"
      }
    }
  },
  // Mainnet, launched 2026-11-15 (deployments/mainnet.json, SHA-256 a76316edd3aa23badfafcd60b88275d29230c2a23290e8f8acc547a9dc456443).
  mainnet: {
    nodeUrl: "",
    apiUrl: "https://api.trestly.io/api/v1",
    covenantId: "50b3477e7368d0c5bfbd64483b4607350ec411377972f33e40b2d4b6d1513fd3",
    poolId: "28e7758e6fc0e2054cceb7f87f9da44a53accfa0a1795c8075c80fb99c83aaad",
    tokenValue: DEFAULT_TOKEN_VALUE,
    positionValue: DEFAULT_POSITION_VALUE,
    burnValue: DEFAULT_BURN_VALUE,
    chains: {
      ethereum: {
        name: "Ethereum",
        chainId: 1,
        gasSymbol: "ETH",
        vault: "0xfa9869982542FB20baD929789B252b7b06EeE10e",
        token: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        decimals: 6,
        blocklist: "isBlackListed",
        rpcUrls: ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"],
        explorerTx: "https://etherscan.io/tx/{tx}"
      },
      bsc: {
        name: "BNB Chain",
        chainId: 56,
        gasSymbol: "BNB",
        vault: "0xfa9869982542FB20baD929789B252b7b06EeE10e",
        token: "0x55d398326f99059fF775485246999027B3197955",
        decimals: 18,
        blocklist: null,
        rpcUrls: ["https://bsc-rpc.publicnode.com", "https://bsc-dataseed.bnbchain.org"],
        explorerTx: "https://bscscan.com/tx/{tx}"
      }
    }
  },
  // The local development stack (bridge/devnet: npm run local:stack): kaspad
  // simnet in Docker, two Hardhat chains with vaults, the signers and the
  // coordinator. The covenant and pool IDs change with every new stack; on
  // this network only, the wallet offers to take the stack's new deployment
  // in one tap (config/local.ts).
  simnet: {
    nodeUrl: "ws://127.0.0.1:18610",
    apiUrl: "http://127.0.0.1:9100/api/v1",
    covenantId: TO_BE_FILLED,
    poolId: TO_BE_FILLED,
    tokenValue: DEFAULT_TOKEN_VALUE,
    positionValue: DEFAULT_POSITION_VALUE,
    burnValue: DEFAULT_BURN_VALUE,
    chains: {
      ethereum: {
        name: "Ethereum (local)",
        chainId: 31337,
        gasSymbol: "ETH",
        vault: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
        token: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
        decimals: 6,
        blocklist: "isBlackListed",
        rpcUrls: ["http://127.0.0.1:8545"],
        explorerTx: ""
      },
      bsc: {
        name: "BNB Chain (local)",
        chainId: 31338,
        gasSymbol: "BNB",
        vault: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
        token: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
        decimals: 18,
        blocklist: null,
        rpcUrls: ["http://127.0.0.1:8546"],
        explorerTx: ""
      }
    }
  }
};

// ../../../kusdt-open/bridge/packages/kaspa/src/node.ts
var RESOLVERS = [
  "eric.kaspa.stream",
  "maxim.kaspa.stream",
  "sean.kaspa.stream",
  "troy.kaspa.stream",
  "john.kaspa.red",
  "mike.kaspa.red",
  "paul.kaspa.red",
  "alex.kaspa.red",
  "jake.kaspa.green",
  "mark.kaspa.green",
  "adam.kaspa.green",
  "liam.kaspa.green",
  "noah.kaspa.blue",
  "ryan.kaspa.blue",
  "jack.kaspa.blue",
  "luke.kaspa.blue"
];
var NODE_HOST = /^[a-z0-9-]+\.kaspa\.(stream|red|green|blue)$/;
var shuffled = (a) => a.map((v) => [Math.random(), v]).sort((x, y) => x[0] - y[0]).map((x) => x[1]);
var RESOLVER_BACKOFF_MS = 10 * 6e4;
var RESOLVER_ANSWER_MAX = 16384;
async function resolverAnswer(r) {
  if (!r.body) throw new Error("no resolver answer");
  if (Number(r.headers.get("content-length") ?? 0) > RESOLVER_ANSWER_MAX) {
    await r.body.cancel().catch(() => {
    });
    throw new Error("resolver answer too long");
  }
  const reader = r.body.getReader();
  const decoder = new TextDecoder();
  let size = 0, text = "";
  for (; ; ) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > RESOLVER_ANSWER_MAX) {
      await reader.cancel().catch(() => {
      });
      throw new Error("resolver answer too long");
    }
    text += decoder.decode(value, { stream: true });
  }
  return JSON.parse(text + decoder.decode());
}
var resolverDown = /* @__PURE__ */ new Map();
async function resolveNode(net, avoid = /* @__PURE__ */ new Set(), now = Date.now()) {
  const ask = async (host) => {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 4e3);
    try {
      const r = await fetch(`https://${host}/v2/kaspa/${net.name}/tls/wrpc/borsh`, { cache: "no-store", signal: ctrl.signal }).catch((e) => {
        resolverDown.set(host, now + RESOLVER_BACKOFF_MS);
        throw e;
      });
      if (!r.ok) {
        resolverDown.set(host, now + RESOLVER_BACKOFF_MS);
        throw new Error(`resolver ${host} answered ${r.status}`);
      }
      const d = await resolverAnswer(r).catch((e) => {
        resolverDown.set(host, now + RESOLVER_BACKOFF_MS);
        throw e;
      });
      const u = typeof d?.url === "string" ? new URL(d.url) : null;
      if (!u || u.protocol !== "wss:" || !NODE_HOST.test(u.hostname) || !u.pathname.endsWith("/wrpc/borsh")) throw new Error("bad node");
      const url = `wss://${u.hostname}${u.pathname.replace(/\/wrpc\/borsh$/, "/wrpc/json")}`;
      if (avoid.has(url)) throw new Error("avoided node");
      return url;
    } finally {
      clearTimeout(t);
    }
  };
  const up = RESOLVERS.filter((h) => (resolverDown.get(h) ?? 0) <= now);
  const order = shuffled(up.length ? up : RESOLVERS);
  for (let i = 0; i < order.length; i += 3) {
    try {
      return await Promise.any(order.slice(i, i + 3).map(ask));
    } catch {
    }
  }
  throw new Error("No public Kaspa node is reachable.");
}

// ../../../kusdt-open/wallet/extension/src/lib/bigint.ts
var MAX_DIGITS = 80;
function toBig(v, what = "number") {
  if (typeof v === "bigint") return v;
  if (typeof v === "string" && v.length <= MAX_DIGITS && /^-?\d+$/.test(v)) return BigInt(v);
  if (typeof v === "number" && Number.isSafeInteger(v)) return BigInt(v);
  throw new Error(`Unexpected ${what}.`);
}
function toNat(v, what = "number") {
  const b = toBig(v, what);
  if (b < 0n) throw new Error(`Unexpected negative ${what}.`);
  return b;
}
var isHex = (s, len) => typeof s === "string" && /^[0-9a-f]*$/.test(s) && s.length % 2 === 0 && (len == null || s.length === len);
var isHex32 = (s) => isHex(s, 64);
var ZERO32 = "00".repeat(32);

// ../../../kusdt-open/wallet/extension/src/lib/format.ts
function formatUnits(v, decimals, maxFrac = decimals) {
  const neg = v < 0n;
  if (neg) v = -v;
  const base = 10n ** BigInt(decimals);
  const whole = (v / base).toLocaleString("en-US");
  let frac = (v % base).toString().padStart(decimals, "0").slice(0, maxFrac).replace(/0+$/, "");
  if (!frac && v > 0n && v < base && maxFrac < decimals && v % base !== 0n && whole === "0") frac = "0".repeat(Math.max(0, maxFrac - 1)) + "1";
  return `${neg ? "-" : ""}${whole}${frac ? "." + frac : ""}`;
}
var fmtKas = (sompi, maxFrac = 8) => formatUnits(sompi, 8, maxFrac);
var fmtUsdt = (units, maxFrac = 6) => formatUnits(units, 6, maxFrac);
function quoted(text, max = 200) {
  const plain = text.replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").replace(/\s+/g, " ").trim();
  return `"${plain.length > max ? `${plain.slice(0, max)}\u2026` : plain}"`;
}

// ../../../kusdt-open/wallet/extension/src/kaspa/node.ts
var NodeRejected = class extends Error {
  constructor(said, message = `The Kaspa node refused the transaction: it said ${quoted(said)}.`) {
    super(message);
    this.said = said;
  }
  said;
};
var NodeError = class extends RpcError {
  constructor(method, said) {
    super(method, said);
    this.said = said;
    this.message = `The Kaspa node's answer to ${method} was an error: ${quoted(said)}.`;
  }
  said;
};
var NoAnswer = class extends Error {
};
var MaybeSent = class extends Error {
  constructor(txid, merge = false) {
    super(`The Kaspa node did not answer, so transaction ${txid} may have been sent. It is followed in the wallet's Activity: check there before trying again.`);
    this.txid = txid;
    this.merge = merge;
  }
  txid;
  merge;
};
var MIN_FEERATE = 100;
var MAX_FEERATE = 2e3;
var FOUND_MAX = 512;
function spkHexOf(spk) {
  if (typeof spk === "string" && isHex(spk) && spk.length >= 4) return spk;
  const o = spk;
  if (o && typeof o.version === "number" && isHex(o.scriptPublicKey)) return o.version.toString(16).padStart(4, "0") + o.scriptPublicKey;
  throw new Error("Unexpected script from the Kaspa node.");
}
var expectedSpk = (address, prefix) => {
  const s = scriptForAddress(address, prefix);
  return s.version.toString(16).padStart(4, "0") + bytesToHex(s.script);
};
var KaspaNodeClient = class {
  constructor(network, url, timeoutMs = 2e4) {
    this.network = network;
    this.url = url;
    this.timeoutMs = timeoutMs;
  }
  network;
  url;
  timeoutMs;
  rpc = null;
  /** The public node the open connection goes to (empty with a configured node). */
  current = "";
  /** Public nodes that timed out this session: the resolver is asked for another. */
  slow = /* @__PURE__ */ new Set();
  /** The verdicts on mempool transactions, kept between looks (R12-WW-3): the wallet looks every few seconds. */
  verdicts = new VerdictMemory();
  /**
   * The DAA score each coin was accepted at, for the coins this client found itself at addresses the wallet asked
   * about ("txid:index"): what a claimed age is checked against when the caller of mempoolJudged did not find the
   * coin in the same look. The newest few hundred.
   */
  found = /* @__PURE__ */ new Map();
  get prefix() {
    return KASPA_NETWORKS[this.network].prefix;
  }
  async pick() {
    if (this.url) return this.url;
    const net = KASPA_NETWORKS[this.network];
    try {
      return await resolveNode(net, this.slow);
    } catch (e) {
      if (!this.slow.size) throw e;
      this.slow.clear();
      return resolveNode(net);
    }
  }
  connect() {
    this.rpc ??= (async () => {
      const url = await this.pick();
      this.current = this.url ? "" : url;
      const rpc = await new KaspaRpc(url, this.timeoutMs).connect();
      const info = await rpc.call("getServerInfo", {}).catch((e) => {
        throw e instanceof RpcError && !(e instanceof RpcTooLargeError) && e.message !== "getServerInfo: timed out" ? new NodeError("getServerInfo", e.message) : e;
      });
      const problem = info?.networkId !== this.network ? `The Kaspa node serves ${info?.networkId == null ? "an unknown network" : quoted(String(info.networkId), 40)}, not ${this.network}.` : info.hasUtxoIndex !== true ? "The Kaspa node has no UTXO index." : this.network !== "simnet" && info.isSynced !== true ? "The Kaspa node is not synced yet." : null;
      if (problem) {
        rpc.close();
        throw new Error(problem);
      }
      return rpc;
    })();
    this.rpc.catch(() => {
      this.rpc = null;
    });
    return this.rpc;
  }
  /**
   * A call on the open connection. A node's refusal keeps it. A lost connection, or
   * a timeout (a node that went silent, or one too slow to answer), drops it: a
   * timed-out public node is skipped for the session, and a read is asked once
   * more on a fresh connection. A transaction is never sent twice by itself.
   */
  async call(method, params = {}, retry = true) {
    const rpc = await this.connect();
    try {
      return await rpc.call(method, params);
    } catch (e) {
      const timedOut2 = e instanceof RpcError && e.message === `${method}: timed out`;
      if (!(e instanceof RpcError) || timedOut2) {
        if (this.rpc) this.rpc = null;
        rpc.close();
        if (timedOut2 && this.current) this.slow.add(this.current);
        if (timedOut2 && retry && method !== "submitTransaction") return this.call(method, params, false);
        if (method === "submitTransaction" && e.message !== "not connected") throw new NoAnswer(e.message);
        throw e;
      }
      throw e instanceof RpcTooLargeError ? e : new NodeError(method, e.message);
    }
  }
  async utxos(addresses) {
    if (addresses.length === 0) return [];
    const asked = new Set(addresses);
    const res = await this.call("getUtxosByAddresses", { addresses });
    if (!Array.isArray(res?.entries)) throw new Error("Unexpected answer from the Kaspa node.");
    const seen = /* @__PURE__ */ new Set();
    const out = [];
    for (const e of res.entries) {
      const txid = e?.outpoint?.transactionId, index = e?.outpoint?.index;
      if (!asked.has(e?.address) || !isHex(txid, 64) || !Number.isInteger(index) || index < 0) throw new Error("Unexpected coin data from the Kaspa node.");
      const spk = spkHexOf(e.utxoEntry?.scriptPublicKey);
      if (spk !== expectedSpk(e.address, this.prefix)) throw new Error("The Kaspa node returned a coin that does not match its address.");
      const covenantId = e.utxoEntry?.covenantId ?? null;
      if (covenantId !== null && !isHex(covenantId, 64)) throw new Error("Unexpected covenant ID from the Kaspa node.");
      const key = `${txid}:${index}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        address: e.address,
        transactionId: txid,
        index,
        amount: toNat(e.utxoEntry.amount, "amount"),
        scriptPublicKey: spk,
        blockDaaScore: toNat(e.utxoEntry.blockDaaScore ?? 0, "DAA score"),
        isCoinbase: e.utxoEntry.isCoinbase === true,
        covenantId
      });
    }
    for (const u of out.slice(-FOUND_MAX)) {
      this.found.delete(`${u.transactionId}:${u.index}`);
      this.found.set(`${u.transactionId}:${u.index}`, u.blockDaaScore);
    }
    while (this.found.size > FOUND_MAX) this.found.delete(this.found.keys().next().value);
    return out;
  }
  async mempool(addresses) {
    if (addresses.length === 0) return [];
    const res = await this.call("getMempoolEntriesByAddresses", { addresses, includeOrphanPool: false, filterTransactionPool: false });
    return Array.isArray(res?.entries) ? res.entries : [];
  }
  async mempoolOutputs(addresses) {
    const asked = new Set(addresses);
    const out = [];
    for (const entry of await this.mempool(addresses)) {
      if (!asked.has(entry?.address)) continue;
      const want = expectedSpk(entry.address, this.prefix);
      for (const r of entry.receiving ?? []) {
        const tx = r?.transaction;
        const txid = tx?.verboseData?.transactionId;
        if (!isHex(txid, 64) || !Array.isArray(tx?.outputs)) continue;
        tx.outputs.forEach((o, index) => {
          let spk;
          try {
            spk = spkHexOf(o?.scriptPublicKey);
          } catch {
            return;
          }
          if (spk !== want) return;
          const covenantId = o?.covenant?.covenantId ?? null;
          if (covenantId !== null && !isHex(covenantId, 64)) return;
          out.push({ address: entry.address, transactionId: txid, index, amount: toNat(o.value, "amount"), scriptPublicKey: spk, covenantId });
        });
      }
    }
    return out;
  }
  async inMempool(txid) {
    try {
      const r = await this.call("getMempoolEntry", { transactionId: txid, includeOrphanPool: false, filterTransactionPool: false });
      return !!r?.mempoolEntry?.transaction;
    } catch (e) {
      if (e instanceof NodeError && /not found/i.test(e.said)) return false;
      throw e;
    }
  }
  async mempoolSpent(addresses) {
    const spent = /* @__PURE__ */ new Set();
    for (const entry of await this.mempool(addresses)) {
      for (const s of entry?.sending ?? []) {
        for (const i of s?.transaction?.inputs ?? []) {
          const p = i?.previousOutpoint;
          if (isHex(p?.transactionId, 64) && Number.isInteger(p?.index)) spent.add(`${p.transactionId}:${p.index}`);
        }
      }
    }
    return spent;
  }
  async mempoolJudged(addresses, wanted, accepted) {
    const heldBy = /* @__PURE__ */ new Map(), unminable = /* @__PURE__ */ new Map();
    if (addresses.length === 0 || wanted.length === 0) return { heldBy, unminable };
    const answer = { entries: await this.mempool(addresses) };
    const call = (method, params) => this.call(method, params);
    const reads = nodeMinableReads(call, (o) => accepted?.get(`${o.transactionId}:${o.index}`) ?? this.found.get(`${o.transactionId}:${o.index}`));
    const known = /* @__PURE__ */ new Map();
    for (const s of sendingIn(answer)) {
      const spends = wanted.filter((w) => spendsOutpoint(s.tx, { transactionId: w.txid, index: w.index }));
      if (!spends.length) continue;
      const v = await this.verdicts.judge(s.txid, s.tx, reads, { known });
      if (!v.minable) for (const w of spends) heldBy.set(`${w.txid}:${w.index}`, { txid: s.txid, why: v.why });
    }
    const made = new Set(wanted.map((w) => w.txid));
    for (const r of receivingIn(answer)) {
      if (!made.has(r.txid)) continue;
      const v = await this.verdicts.judge(r.txid, r.tx, reads, { known });
      if (!v.minable) unminable.set(r.txid, v.why);
    }
    return { heldBy, unminable };
  }
  async feerate() {
    try {
      const r = await this.call("getFeeEstimate", {});
      const f = r?.estimate?.normalBuckets?.[0]?.feerate ?? r?.estimate?.priorityBucket?.feerate;
      return clampFeerate(f);
    } catch {
      return MIN_FEERATE;
    }
  }
  async virtualDaa() {
    const r = await this.call("getBlockDagInfo", {});
    return toNat(r?.virtualDaaScore, "DAA score");
  }
  async submit(transactionJson) {
    let r;
    try {
      r = await this.call("submitTransaction", `{"transaction":${transactionJson},"allowOrphan":false}`);
    } catch (e) {
      if (e instanceof RpcError) throw new NodeRejected(e instanceof NodeError ? e.said : e.message);
      throw e;
    }
    if (!isHex(r?.transactionId, 64)) throw new Error("Unexpected answer from the Kaspa node.");
    return r.transactionId;
  }
  close() {
    const r = this.rpc;
    this.rpc = null;
    r?.then((x) => x.close()).catch(() => {
    });
  }
};
function clampFeerate(f) {
  if (typeof f !== "number" || !Number.isFinite(f)) return MIN_FEERATE;
  return Math.min(MAX_FEERATE, Math.max(MIN_FEERATE, Math.ceil(f)));
}

// ../../../kusdt-open/wallet/extension/src/lib/capped-read.ts
var AnswerTooLong = class extends Error {
  constructor(maxBytes) {
    super(`The answer is longer than ${maxBytes} bytes: refused.`);
    this.maxBytes = maxBytes;
  }
  maxBytes;
};
var MAX_API_ANSWER_BYTES = 8e6;
async function readCapped(res, maxBytes) {
  const told = Number(res.headers?.get("content-length") ?? NaN);
  if (told > maxBytes) {
    await res.body?.cancel().catch(() => {
    });
    throw new AnswerTooLong(maxBytes);
  }
  if (!res.body) return "";
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let size = 0, text = "";
  for (; ; ) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel().catch(() => {
      });
      throw new AnswerTooLong(maxBytes);
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

// ../../../kusdt-open/wallet/extension/src/kusdt/api.ts
var ApiError = class extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
  status;
};
var CoordinatorClient = class {
  constructor(base, fetcher = (...a) => fetch(...a)) {
    this.base = base;
    this.fetcher = fetcher;
    if (!base) throw new Error("No coordinator API is set for this network (Settings).");
    this.base = base.replace(/\/+$/, "");
  }
  base;
  fetcher;
  async req(path, init) {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 15e3);
    try {
      const res = await this.fetcher(this.base + path, {
        method: init?.method ?? "GET",
        signal: ctl.signal,
        cache: "no-store",
        headers: init?.rawBody ? { "content-type": "application/json" } : void 0,
        body: init?.rawBody
      });
      const text = await readCapped(res, MAX_API_ANSWER_BYTES);
      let data = null;
      try {
        data = text ? parseExactJson2(text) : null;
      } catch {
      }
      if (!res.ok) throw new ApiError(`The coordinator answered HTTP ${res.status}${typeof data?.error === "string" ? `: ${quoted(data.error)}` : "."}`, res.status);
      return data;
    } catch (e) {
      if (e instanceof ApiError) throw e;
      if (e instanceof AnswerTooLong) throw new Error("The coordinator API answered more than the wallet reads: refused.");
      throw new Error("Could not reach the coordinator API.");
    } finally {
      clearTimeout(t);
    }
  }
  status() {
    return this.req("/status");
  }
  async tokens(owner) {
    const d = await this.req(`/tokens?owner=${encodeURIComponent(owner)}`);
    return { states: Array.isArray(d?.states) ? d.states : [], unread: Array.isArray(d?.unread) ? d.unread : [] };
  }
  pool() {
    return this.req("/pool");
  }
  async poolMade(txid) {
    return (await this.req(`/pool/made/${encodeURIComponent(txid)}`))?.made;
  }
  async positions(owner) {
    const d = await this.req(`/positions?owner=${encodeURIComponent(owner)}`);
    return { positions: Array.isArray(d?.positions) ? d.positions : [], unread: Array.isArray(d?.unread) ? d.unread : [] };
  }
  deposit(chain, nonce) {
    return this.req(`/deposits/${chain}/${nonce}`);
  }
  redeem(txid, outputIndex) {
    return this.req(`/redeems/${txid}/${outputIndex}`);
  }
  /** By chain code: exactly what the burn owner commits to (SPEC §9). */
  recipient(chain, address) {
    return this.req(`/recipients/${CHAIN_CODE[chain]}/${encodeURIComponent(address)}`);
  }
  /**
   * `{transaction}` carries the node JSON of a submitted burn, inserted as is
   * (it was built by the core and its integers must stay exact). The core's
   * JSON has no verboseData, so the id goes with it as `transactionId`, which
   * the coordinator requires (bridge/services/src/coordinator/api.ts).
   */
  postRedeem(body) {
    const raw = "transaction" in body ? `{"transaction":${body.transaction},"transactionId":${JSON.stringify(body.transactionId)}}` : JSON.stringify(body);
    return this.req("/redeems", { method: "POST", rawBody: raw });
  }
};

// ../../../kusdt-open/wallet/extension/src/lib/storage.ts
function memoryArea() {
  const m = /* @__PURE__ */ new Map();
  return {
    async get(key) {
      return m.get(key);
    },
    async set(values) {
      for (const [k, v] of Object.entries(values)) m.set(k, structuredClone(v));
    },
    async remove(...keys) {
      for (const k of keys) m.delete(k);
    }
  };
}
function chromeArea(name) {
  const c = globalThis.chrome;
  const area2 = c?.storage?.[name];
  if (!area2) return null;
  return {
    get: (key) => new Promise((r) => area2.get([key], (v) => r(v?.[key]))),
    set: (values) => new Promise((r) => area2.set(values, () => r())),
    remove: (...keys) => new Promise((r) => area2.remove(keys, () => r()))
  };
}
var local = chromeArea("local") ?? memoryArea();
var session = chromeArea("session") ?? memoryArea();

// ../../../kusdt-open/wallet/extension/src/kusdt/pending.ts
var KEY = (network) => `kusdt.pending.${network}`;
var TTL_MS = 10 * 6e4;
async function load(network) {
  const s = await session.get(KEY(network)) ?? {};
  const now = Date.now();
  for (const [k, t] of Object.entries(s)) if (t <= now) delete s[k];
  return s;
}
async function markSpent(network, outpoints) {
  const s = await load(network);
  const until = Date.now() + TTL_MS;
  for (const o of outpoints) s[o] = until;
  await session.set({ [KEY(network)]: s });
}
async function releaseSpent(network, outpoints) {
  const s = await load(network);
  for (const o of outpoints) delete s[o];
  await session.set({ [KEY(network)]: s });
}
async function pendingSet(network) {
  return new Set(Object.keys(await load(network)));
}
function inputsOf(transactionJson) {
  const tx = JSON.parse(transactionJson);
  return (tx.inputs ?? []).map((i) => `${i.previousOutpoint?.transactionId}:${i.previousOutpoint?.index}`);
}

// ../../../kusdt-open/wallet/extension/src/kaspa/kas.ts
async function kasBalance(node, network, addresses) {
  const [all, pending, inMempool] = await Promise.all([node.utxos(addresses), pendingSet(network), node.mempoolSpent(addresses).catch(() => /* @__PURE__ */ new Set())]);
  const plain = all.filter((u) => u.covenantId === null && !pending.has(`${u.transactionId}:${u.index}`) && !inMempool.has(`${u.transactionId}:${u.index}`));
  const utxos = plain.map((u) => ({
    txid: u.transactionId,
    index: u.index,
    amount: u.amount,
    script: { version: parseInt(u.scriptPublicKey.slice(0, 4), 16), script: hexToBytes(u.scriptPublicKey.slice(4)) },
    blockDaaScore: u.blockDaaScore,
    isCoinbase: u.isCoinbase,
    address: u.address
  }));
  const daa = utxos.some((u) => u.isCoinbase) ? await node.virtualDaa() : null;
  const total = utxos.reduce((s, u) => s + u.amount, 0n);
  const spendable = spendableUtxos(utxos, { virtualDaaScore: daa }).reduce((s, u) => s + u.amount, 0n);
  return { total, spendable, utxos: spendableUtxos(utxos, { virtualDaaScore: daa }) };
}

// ../../../kusdt-open/bridge/packages/protocol/src/pool.ts
var BPS = 10000n;
var MAX_OPERAND = 2305843009213693951n;
var SWAP_INPUT_MOST = MAX_OPERAND / BPS;

// ../../../kusdt-open/bridge/packages/protocol/src/minter.ts
var MAX_TX_INPUTS = 8;
var UNACCEPTED_DAA_SCORE = 0xffffffffffffffffn;
var ZERO32_HEX = "00".repeat(32);
var MAX_AGE_DAA = (1n << 32n) - 1n;

// ../../../kusdt-open/bridge/packages/protocol/src/pool-follow.ts
var ZERO322 = "00".repeat(32);
function reserveMadeBy(made, at, script, ids) {
  const body = idBodyOf(made);
  if (!body || body.version < 1 || transactionIdOf(body) !== at.transactionId.toLowerCase()) return null;
  const kusdt = ids.covenantId.toLowerCase(), pool = ids.poolId.toLowerCase();
  const first = body.outputs.findIndex((o) => o.covenant?.covenantId === kusdt);
  if (first !== at.index || body.outputs[first].scriptPublicKey !== script.toLowerCase()) return null;
  return body.outputs.some((o) => o.covenant?.covenantId === pool) ? body.outputs[first].value : null;
}

// ../../../kusdt-open/wallet/extension/src/kusdt/owner.ts
var OWNER_P2PK_SCHNORR = 0;
var OWNER_COVENANT_ID2 = 4;
var plainState = (o, amount) => ({
  amount,
  owner: o.owner,
  ownerScheme: o.ownerScheme,
  borrowScheme: 0,
  borrowGuard: ZERO32,
  extensionCommitment: ZERO32
});
var isPlainStateOf = (s, ownerHex) => s.ownerScheme === OWNER_P2PK_SCHNORR && s.owner === ownerHex && s.borrowScheme === 0 && s.borrowGuard === ZERO32 && s.extensionCommitment === ZERO32 && s.amount >= 0n;

// ../../../kusdt-open/wallet/extension/src/kusdt/unreadable.ts
var UNREADABLE = {
  /** How long an address whose list was too long is not asked about again. */
  fullMs: 10 * 6e4,
  /** The same for one whose read timed out: much shorter, a slow node recovers (and the pool's own address is read this way too). */
  slowMs: 6e4,
  /** The most addresses remembered. */
  keep: 64,
  /** The most addresses read on their own in one look. */
  singles: 64,
  /** Reads on their own that may time out in one look before the rest is left unasked. */
  timeouts: 2
};
var KEY2 = (network) => `kusdt.unreadable.${network}`;
var tooLong = (e) => e instanceof RpcTooLargeError;
var timedOut = (e) => e instanceof RpcError && !(e instanceof RpcTooLargeError) && /timed out$/.test(e.message);
var cannotList = (e) => tooLong(e) || timedOut(e);
async function load2(network) {
  const s = await session.get(KEY2(network)).catch(() => void 0);
  const now = Date.now(), until = {};
  for (const [a, t] of Object.entries(s?.until ?? {})) if (typeof t === "number" && t > now) until[a] = t;
  return { until, next: typeof s?.next === "number" && Number.isSafeInteger(s.next) && s.next >= 0 ? s.next : 0 };
}
async function save(network, s) {
  const newest = Object.entries(s.until).sort((a, b) => b[1] - a[1]).slice(0, UNREADABLE.keep);
  await session.set({ [KEY2(network)]: { until: Object.fromEntries(newest), next: s.next } }).catch(() => {
  });
}
async function listAddresses(ctx, addresses) {
  const store = await load2(ctx.network);
  const unread = new Set(addresses.filter((a) => a in store.until));
  const ask = addresses.filter((a) => !unread.has(a));
  if (ask.length === 0) return { utxos: [], unread };
  let first;
  try {
    return { utxos: await ctx.node.utxos(ask), unread };
  } catch (e) {
    if (!cannotList(e)) throw e;
    first = e;
  }
  const utxos = [];
  const now = Date.now();
  const note = (address, e) => {
    unread.add(address);
    store.until[address] = now + (tooLong(e) ? UNREADABLE.fullMs : UNREADABLE.slowMs);
  };
  if (ask.length === 1) note(ask[0], first);
  else {
    const from = ask.length > UNREADABLE.singles ? store.next % ask.length : 0;
    let asked = 0, timeouts = 0;
    for (let i = 0; i < ask.length; i++) {
      const address = ask[(from + i) % ask.length];
      if (asked >= UNREADABLE.singles || timeouts >= UNREADABLE.timeouts) {
        unread.add(address);
        continue;
      }
      asked++;
      try {
        utxos.push(...await ctx.node.utxos([address]));
      } catch (e) {
        if (!cannotList(e)) throw e;
        if (timedOut(e)) timeouts++;
        note(address, e);
      }
    }
    store.next = ask.length > UNREADABLE.singles ? (from + asked) % ask.length : 0;
  }
  await save(ctx.network, store);
  return { utxos, unread };
}

// ../../../kusdt-open/wallet/extension/src/kusdt/known.ts
var KNOWN_KEEP = 600;
var OWNERS_KEEP = 16;
var UNLISTED_AFTER_MS = 10 * 6e4;
var MISSES = 3;
var MISS_SPACING_MS = 6e4;
var OWN_FRESH_MS = 10 * 6e4;
var SPENT_KEEP_MS = 60 * 6e4;
var KEY3 = (network, ownerHex) => `kusdt.known.${network}.${ownerHex}`;
var OWNERS = (network) => `kusdt.known.owners.${network}`;
var time = (v) => v === void 0 || typeof v === "number" && Number.isFinite(v);
var valid = (k) => !!k && isHex32(k.txid) && Number.isInteger(k.index) && k.index >= 0 && /^\d{1,30}$/.test(k.amount) && /^\d{1,30}$/.test(k.kas) && /^\d{1,30}$/.test(k.daa) && (k.spentBy === void 0 || isHex32(k.spentBy)) && time(k.spentAt) && time(k.missAt);
var idOf = (k) => `${k.txid}:${k.index}`;
async function read(network, ownerHex) {
  const list = await local.get(KEY3(network, ownerHex));
  return Array.isArray(list) ? list.filter(valid) : null;
}
async function knownRecord(network, ownerHex) {
  return await read(network, ownerHex) ?? [];
}
async function owners(network) {
  const list = await local.get(OWNERS(network));
  return Array.isArray(list) ? list.filter((o) => isHex32(o)) : [];
}
var queues = /* @__PURE__ */ new Map();
function oneAtATime(key, change) {
  const next = (queues.get(key) ?? Promise.resolve()).then(change, change);
  queues.set(key, next.catch(() => {
  }));
  return next;
}
async function write(network, ownerHex, list, before) {
  const more = (a, b) => {
    if (a.spentBy === void 0 !== (b.spentBy === void 0)) return a.spentBy === void 0 ? -1 : 1;
    const x = BigInt(a.amount), y = BigInt(b.amount);
    return x === y ? b.at - a.at : x > y ? -1 : 1;
  };
  const kept = list.slice().sort(more).slice(0, KNOWN_KEEP);
  if (before && JSON.stringify(before) === JSON.stringify(kept)) return;
  await local.set({ [KEY3(network, ownerHex)]: kept });
  if (before) return;
  const all = [...(await owners(network)).filter((o) => o !== ownerHex), ownerHex];
  for (const gone of all.slice(0, Math.max(0, all.length - OWNERS_KEEP))) await local.remove(KEY3(network, gone));
  await local.set({ [OWNERS(network)]: all.slice(-OWNERS_KEEP) });
}
function updateKnown(network, ownerHex, seen, missing) {
  return oneAtATime(KEY3(network, ownerHex), () => applyLook(network, ownerHex, seen, missing));
}
async function applyLook(network, ownerHex, seen, missing) {
  const before = await read(network, ownerHex);
  const byId = new Map((before ?? []).map((k) => [idOf(k), { ...k }]));
  const now = Date.now();
  const shown = /* @__PURE__ */ new Set();
  for (const s of seen) {
    const old = byId.get(idOf(s));
    const marked = old?.spentBy !== void 0 && now - (old.spentAt ?? 0) < SPENT_KEEP_MS;
    shown.add(idOf(s));
    byId.set(idOf(s), { txid: s.txid, index: s.index, amount: s.amount.toString(), kas: s.kas.toString(), daa: s.daa.toString(), misses: 0, at: old?.at ?? now, ...marked && { spentBy: old.spentBy, spentAt: old.spentAt } });
  }
  const waited = /* @__PURE__ */ new Set();
  const missed = new Set(missing);
  for (const k of [...byId.values()]) {
    if (k.spentBy === void 0) continue;
    waited.add(k.spentBy);
    if (!shown.has(idOf(k)) && !missed.has(idOf(k)) && now - (k.spentAt ?? 0) >= SPENT_KEEP_MS) byId.delete(idOf(k));
  }
  for (const id of missing) {
    const k = byId.get(id);
    if (!k) continue;
    if (k.daa === "0" && (now - k.at < OWN_FRESH_MS || waited.has(k.txid))) continue;
    if (k.missAt !== void 0 && now - k.missAt < MISS_SPACING_MS) continue;
    if (k.misses + 1 >= MISSES) byId.delete(id);
    else {
      k.misses++;
      k.missAt = now;
    }
  }
  await write(network, ownerHex, [...byId.values()], before);
}
async function noteBuilt(ctx, built, spent) {
  const made = /* @__PURE__ */ new Map();
  const now = Date.now();
  for (const o of built.outputs) {
    const t = o.token;
    if (!t || t.ownerScheme !== OWNER_P2PK_SCHNORR || !isHex32(t.owner) || (t.borrowScheme ?? 0) !== 0) continue;
    if ((t.borrowGuard ?? ZERO32) !== ZERO32 || (t.extensionCommitment ?? ZERO32) !== ZERO32) continue;
    const amount = typeof t.amount === "bigint" || typeof t.amount === "number" || typeof t.amount === "string" ? String(t.amount) : "";
    const k = { txid: built.txid, index: o.index, amount, kas: o.value.toString(), daa: "0", misses: 0, at: now };
    if (valid(k)) made.set(t.owner, [...made.get(t.owner) ?? [], k]);
  }
  const gone = new Set(spent ? inputsOf(built.transaction) : []);
  for (const ownerHex of await owners(ctx.network)) {
    await oneAtATime(KEY3(ctx.network, ownerHex), async () => {
      const before = await read(ctx.network, ownerHex);
      if (!before) return;
      const added = made.get(ownerHex) ?? [];
      const ids = new Set(added.map(idOf));
      const marked = before.filter((k) => !ids.has(idOf(k))).map((k) => gone.has(idOf(k)) ? { ...k, spentBy: built.txid, spentAt: now } : k);
      await write(ctx.network, ownerHex, [...marked, ...added], before);
    });
  }
}
async function changeAll(network, change) {
  for (const ownerHex of await owners(network)) {
    await oneAtATime(KEY3(network, ownerHex), async () => {
      const before = await read(network, ownerHex);
      if (before) await write(network, ownerHex, change(before), before);
    });
  }
}
function restoreSpent(network, txid) {
  return changeAll(network, (list) => list.filter((k) => k.txid !== txid).map((k) => {
    if (k.spentBy !== txid) return k;
    const back = { ...k };
    delete back.spentBy;
    delete back.spentAt;
    return back;
  }));
}

// ../../../kusdt-open/wallet/extension/src/kusdt/verify.ts
var VerifyError = class extends Error {
};
var UNREAD = "unread";
var PoolUnreadable = class extends Error {
  constructor(which = "pool") {
    const where = which === "pool" ? "the address the pool is at" : which === "reserve" ? "the address the pool's kUSDT reserve is at" : "the addresses the pool and its kUSDT reserve are at";
    const ends = which === "pool" ? "It ends when the pool next moves to a new address." : "The wallet checks the reserve without that list when the coordinator gives the transaction that made it, and the coordinator gave none that proves it (it may not have seen the reserve move since it started). It ends with the pool's next trade or change of liquidity, not with its routine ticks.";
    super(`The Kaspa node could not list ${where} right now: ${which === "both" ? "they hold" : "it holds"} too many coins (anyone can send coins to an address), or the node is too slow. So this wallet can't check the pool, and builds nothing on a pool it has not checked. ${ends} Nothing was sent, and your funds are where they were.`);
    this.which = which;
  }
  which;
};
function p2shAddressOf(spkHex2, prefix) {
  const m = /^0000aa20([0-9a-f]{64})87$/.exec(spkHex2);
  if (!m) throw new VerifyError("A covenant state has an unexpected script.");
  return encodeKaspaAddress(prefix, 8, hexToBytes(m[1]));
}
function scriptOf2(ctx, actor, state) {
  const spk = ctx.core.call("script", { actor, state }).value.scriptPublicKey;
  if (typeof spk !== "string" || !/^[0-9a-f]+$/.test(spk)) throw new VerifyError("The core gave no script.");
  return spk;
}
var hex32 = (v, what) => {
  if (!isHex32(v)) throw new VerifyError(`A state's ${what} is not 32 bytes of hex.`);
  return v;
};
var byte = (v, what) => {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 255) throw new VerifyError(`A state's ${what} is not a byte.`);
  return v;
};
function parseTokenState(s) {
  if (!s || typeof s !== "object") throw new VerifyError("A token state is missing.");
  return {
    amount: toNat(s.amount, "token amount"),
    owner: hex32(s.owner, "owner"),
    ownerScheme: byte(s.ownerScheme, "owner scheme"),
    borrowScheme: byte(s.borrowScheme ?? 0, "borrow scheme"),
    borrowGuard: hex32(s.borrowGuard ?? ZERO32, "borrow guard"),
    extensionCommitment: hex32(s.extensionCommitment ?? ZERO32, "extension commitment")
  };
}
function parsePoolState(s) {
  if (!s || typeof s !== "object") throw new VerifyError("The pool state is missing.");
  return {
    tokenCovid: hex32(s.tokenCovid, "token covenant ID"),
    kasReserve: toNat(s.kasReserve, "KAS reserve"),
    tokenReserve: toNat(s.tokenReserve, "token reserve"),
    totalShares: toNat(s.totalShares, "total shares"),
    protocolKas: toNat(s.protocolKas, "protocol KAS"),
    protocolTokens: toNat(s.protocolTokens, "protocol tokens"),
    baseValue: toNat(s.baseValue, "base value"),
    admin: hex32(s.admin, "admin"),
    maxOutBps: toNat(s.maxOutBps, "breaker share"),
    windowLen: toNat(s.windowLen, "breaker window"),
    windowCredit: toNat(s.windowCredit, "breaker window start"),
    windowRef: toNat(s.windowRef, "breaker window reserve"),
    // The allowance used (sells less buys, less time): negative after net buying.
    windowOut: toBig(s.windowOut, "breaker window out"),
    paused: s.paused === true,
    guardian: hex32(s.guardian, "guardian")
  };
}
var poolValue = (p) => p.baseValue + p.kasReserve + p.protocolKas;
var reserveStateOf = (poolId, p) => ({
  amount: p.tokenReserve + p.protocolTokens,
  owner: poolId,
  ownerScheme: OWNER_COVENANT_ID2,
  borrowScheme: 0,
  borrowGuard: ZERO32,
  extensionCommitment: ZERO32
});
var sameToken = (a, b) => a.amount === b.amount && a.owner === b.owner && a.ownerScheme === b.ownerScheme && a.borrowScheme === b.borrowScheme && a.borrowGuard === b.borrowGuard && a.extensionCommitment === b.extensionCommitment;
async function locate(ctx, wanted, opts) {
  const prefix = ctx.net.prefix;
  const addresses = [...new Set([...wanted, ...opts.context ?? []].map((w) => p2shAddressOf(w.spk, prefix)))];
  const [{ utxos, unread }, spent] = await Promise.all([listAddresses(ctx, addresses), ctx.node.mempoolSpent(addresses).catch(() => /* @__PURE__ */ new Set())]);
  let pool = null;
  let daa = null;
  let judged;
  const judge = async () => {
    if (judged !== void 0 || !ctx.node.mempoolJudged) return judged;
    const accepted = new Map(utxos.map((u) => [`${u.transactionId}:${u.index}`, u.blockDaaScore]));
    judged = await ctx.node.mempoolJudged(addresses, wanted.map((w) => ({ txid: w.txid, index: w.index })), accepted).catch(() => false);
    return judged;
  };
  const out = [];
  for (const w of wanted) {
    let heldBy;
    if (spent.has(`${w.txid}:${w.index}`)) {
      const j2 = await judge();
      heldBy = j2 ? j2.heldBy.get(`${w.txid}:${w.index}`)?.txid : void 0;
      if (!heldBy) {
        out.push(null);
        continue;
      }
    }
    if (unread.has(p2shAddressOf(w.spk, prefix))) {
      out.push(UNREAD);
      continue;
    }
    const u = utxos.find((x) => x.transactionId === w.txid && x.index === w.index);
    if (u) {
      const ok = u.scriptPublicKey === w.spk && u.covenantId === w.covenantId && (w.amount == null || u.amount === w.amount);
      out.push(ok ? { transactionId: u.transactionId, index: u.index, amount: u.amount, scriptPublicKey: u.scriptPublicKey, blockDaaScore: u.blockDaaScore, isCoinbase: false, covenantId: u.covenantId, confirmed: true, ...heldBy && { heldBy } } : null);
      continue;
    }
    if (!opts.mempool || heldBy) {
      out.push(null);
      continue;
    }
    pool ??= await ctx.node.mempoolOutputs(addresses).catch(() => []);
    const m = pool.find((x) => x.transactionId === w.txid && x.index === w.index);
    const j = m ? await judge() : void 0;
    if (m && (j === false || j?.unminable.has(m.transactionId))) {
      out.push(null);
      continue;
    }
    if (m && m.scriptPublicKey === w.spk && m.covenantId === w.covenantId && (w.amount == null || m.amount === w.amount)) {
      daa ??= await ctx.node.virtualDaa();
      out.push({ transactionId: m.transactionId, index: m.index, amount: m.amount, scriptPublicKey: m.scriptPublicKey, blockDaaScore: daa, isCoinbase: false, covenantId: m.covenantId, confirmed: false });
    } else out.push(null);
  }
  return out;
}
var outpointOf2 = (u) => {
  if (!u || typeof u !== "object" || !/^[0-9a-f]{64}$/.test(String(u.transactionId)) || !Number.isInteger(u.index) || u.index < 0) {
    throw new VerifyError("A state has no valid outpoint.");
  }
  return { txid: u.transactionId, index: u.index };
};
var MAX_LISTED = 500;
var natOrNull = (v) => {
  try {
    return toNat(v);
  } catch {
    return null;
  }
};
async function verifyTokenStates(ctx, listed2, ownerHex, known = [], complete = false) {
  const covenantId = ctx.config.covenantId;
  if (!isHex32(covenantId)) throw new VerifyError("No kUSDT deployment is set for this network.");
  const candidates = [];
  const now = Date.now();
  let rejected = 0;
  const seen = /* @__PURE__ */ new Map();
  for (const l of listed2.slice(0, MAX_LISTED)) {
    try {
      const state = parseTokenState(l?.state);
      if (!isPlainStateOf(state, ownerHex)) {
        rejected++;
        continue;
      }
      const { txid, index } = outpointOf2(l.utxo);
      if (seen.has(`${txid}:${index}`)) continue;
      seen.set(`${txid}:${index}`, candidates.length);
      candidates.push({ state, want: { txid, index, spk: scriptOf2(ctx, "KCC20", state), covenantId }, kas: natOrNull(l.utxo.amount), daa: natOrNull(l.utxo.blockDaaScore) ?? 0n, listed: true, at: now });
    } catch {
      rejected++;
    }
  }
  for (const k of known) {
    const at = seen.get(`${k.txid}:${k.index}`);
    const state = { amount: BigInt(k.amount), owner: ownerHex, ownerScheme: 0, borrowScheme: 0, borrowGuard: ZERO32, extensionCommitment: ZERO32 };
    if (at !== void 0) {
      const c = candidates[at];
      if (c.state.amount !== state.amount) {
        c.state = state;
        c.want = { ...c.want, spk: scriptOf2(ctx, "KCC20", state) };
      }
      c.kas = BigInt(k.kas);
      c.daa = BigInt(k.daa);
      if (k.spentBy !== void 0) c.spent = true;
      continue;
    }
    seen.set(`${k.txid}:${k.index}`, candidates.length);
    candidates.push({ state, want: { txid: k.txid, index: k.index, spk: scriptOf2(ctx, "KCC20", state), covenantId }, kas: BigInt(k.kas), daa: BigInt(k.daa), listed: false, at: k.at, ...k.spentBy !== void 0 && { spent: true } });
  }
  if (candidates.length === 0) return { verified: [], rejected, unread: [], unreadNoRecord: 0, missing: [] };
  const found = await locate(ctx, candidates.map((c) => c.want), { mempool: false });
  const verified = [], unread = [], missing = [];
  let unreadNoRecord = 0;
  found.forEach((u, i) => {
    const c = candidates[i];
    if (u === UNREAD) {
      if (c.spent) return;
      if (!c.listed && complete && now - c.at >= UNLISTED_AFTER_MS) missing.push(`${c.want.txid}:${c.want.index}`);
      if (c.kas === null) {
        unreadNoRecord++;
        return;
      }
      unread.push({ state: c.state, utxo: { transactionId: c.want.txid, index: c.want.index, amount: c.kas, scriptPublicKey: c.want.spk, blockDaaScore: c.daa, isCoinbase: false, covenantId, confirmed: true, unchecked: true } });
    } else if (u) verified.push({ utxo: u, state: c.state });
    else {
      missing.push(`${c.want.txid}:${c.want.index}`);
      if (c.listed) rejected++;
    }
  });
  return { verified, rejected, unread, unreadNoRecord, missing };
}
var isUnopened = (p) => p.totalShares === 0n && p.kasReserve === 0n && p.tokenReserve === 0n && p.protocolTokens === 0n;
function openedPool(vp) {
  if (!vp.reserve || vp.pool.state.totalShares === 0n) throw new Error("The pool has no liquidity yet.");
  return { pool: vp.pool, reserve: vp.reserve };
}
function confirmedPool(ctx, answer, poolId) {
  try {
    const named = answer.confirmed?.pool;
    if (!named) return [];
    return [{ ...outpointOf2(named.utxo), spk: scriptOf2(ctx, "Pool", parsePoolState(named.state)), covenantId: poolId }];
  } catch {
    return [];
  }
}
var madeSeen = /* @__PURE__ */ new Map();
async function verifyPool(ctx, answer) {
  const { covenantId, poolId } = ctx.config;
  if (!isHex32(covenantId) || !isHex32(poolId)) throw new VerifyError("No pool is set for this network.");
  if (!answer?.pool) throw new VerifyError("The coordinator gave no pool.");
  const pool = parsePoolState(answer.pool.state);
  if (pool.tokenCovid !== covenantId) throw new VerifyError("The pool trades another token than kUSDT.");
  if (!answer.reserve) {
    if (!isUnopened(pool)) throw new VerifyError("The coordinator gave no pool reserve.");
    const [pu2] = await locate(ctx, [{ ...outpointOf2(answer.pool.utxo), spk: scriptOf2(ctx, "Pool", pool), covenantId: poolId, amount: poolValue(pool) }], { mempool: true });
    if (pu2 === UNREAD) throw new PoolUnreadable();
    if (!pu2) throw new VerifyError("The pool state could not be found on the Kaspa node (it may have just changed).");
    return { pool: { utxo: pu2, state: pool }, reserve: null };
  }
  const reserve = parseTokenState(answer.reserve.state);
  const expected = reserveStateOf(poolId, pool);
  if (!sameToken(reserve, expected)) throw new VerifyError("The pool reserve does not match the pool.");
  const p = outpointOf2(answer.pool.utxo), r = outpointOf2(answer.reserve.utxo);
  const rspk = scriptOf2(ctx, "KCC20", reserve);
  const wanted = { ...p, spk: scriptOf2(ctx, "Pool", pool), covenantId: poolId, amount: poolValue(pool) };
  const context = confirmedPool(ctx, answer, poolId).filter((c) => c.txid !== p.txid || c.index !== p.index);
  const body = madeSeen.get(r.txid) ?? (answer.reserve.made === r.txid ? await ctx.api?.poolMade?.(r.txid).catch(() => void 0) : void 0);
  const made = reserveMadeBy(body, { transactionId: r.txid, index: r.index }, rspk, { covenantId, poolId });
  if (made !== null) {
    madeSeen.delete(r.txid);
    madeSeen.set(r.txid, body);
    if (madeSeen.size > 8) madeSeen.delete(madeSeen.keys().next().value);
  }
  const withPool = made !== null && r.txid === p.txid;
  const [pu, ru] = await locate(ctx, withPool ? [wanted] : [wanted, { ...r, spk: rspk, covenantId }], { mempool: true, context });
  if (pu === UNREAD) throw new PoolUnreadable(!withPool && ru === UNREAD ? "both" : "pool");
  if (!pu) throw new VerifyError("The pool state could not be found on the Kaspa node (it may have just changed).");
  if (!withPool) {
    if (ru !== UNREAD) {
      if (!ru) throw new VerifyError("The pool state could not be found on the Kaspa node (it may have just changed).");
      return { pool: { utxo: pu, state: pool }, reserve: { utxo: ru, state: reserve } };
    }
    if (made === null) throw new PoolUnreadable("reserve");
  }
  const confirmed = withPool ? pu.confirmed !== false : pu.confirmed !== false || !await ctx.node.inMempool(r.txid);
  return {
    pool: { utxo: pu, state: pool },
    reserve: { utxo: { transactionId: r.txid, index: r.index, amount: made, scriptPublicKey: rspk, blockDaaScore: pu.blockDaaScore, isCoinbase: false, covenantId, confirmed }, state: reserve }
  };
}
async function verifyPosition(ctx, txid, index, state) {
  const [u] = await locate(ctx, [{ txid, index, spk: scriptOf2(ctx, "Position", state), covenantId: ctx.config.poolId }], { mempool: true });
  return u === UNREAD ? UNREAD : u ? { utxo: u, state } : null;
}

// ../../../kusdt-open/wallet/extension/src/kusdt/inputs.ts
var COVENANT_INPUTS = {
  "pool-buy": 2,
  // pool, reserve
  "pool-init": 2,
  // pool, provider
  "pool-sell": 3,
  // pool, reserve, payer
  "pool-add": 3,
  // pool, reserve, provider
  "pool-remove": 3
  // pool, position, reserve
};
function fundingCap(command) {
  const covenant = COVENANT_INPUTS[command];
  return covenant === void 0 ? null : MAX_TX_INPUTS - covenant;
}
var isSchnorrP2pk = (spkHex2) => /^000020[0-9a-f]{64}ac$/.test(spkHex2);
var MergeCoinsFirst = class extends Error {
  constructor(cap, coins, lost) {
    super(lost == null ? `Your KAS is in ${coins} coins, and the ${cap} largest are not enough for this: a pool transaction takes at most ${MAX_TX_INPUTS} inputs, ${MAX_TX_INPUTS - cap} of them the pool's own. Merge your KAS first: send all of it to your own address (Send, KAS, Max), and once it is back as one coin, try again. Nothing was sent.` : `Your KAS is in ${coins} coins, and a pool transaction takes at most ${MAX_TX_INPUTS} inputs, ${MAX_TX_INPUTS - cap} of them the pool's own: the ${cap} it can take would leave about ${kasText(lost)} KAS of change, too little for the network to keep, and it would go to the network fee. Merge your KAS first: send all of it to your own address (Send, KAS, Max), and once it is back as one coin, try again; or change the amount a little. Nothing was sent.`);
    this.cap = cap;
    this.coins = coins;
    this.lost = lost;
  }
  cap;
  coins;
  lost;
  kind = "merge-coins";
};
var kasText = (sompi) => `${sompi / 100000000n}.${(sompi % 100000000n / 1000000n).toString().padStart(2, "0")}`;
var NotInBlockYet = class extends Error {
  constructor(what) {
    super(what === "position" ? "The deposit that made this position is not in a block yet, and the pool has moved since: the pool takes the position once it is (a few seconds). Nothing was sent; try again in a moment." : what === "token" ? "The kUSDT this spends is in a transaction that is not in a block yet: the pool takes it once it is (a few seconds). Nothing was sent; try again in a moment." : "A coin this spends is in a transaction that is not in a block yet: the pool takes it once it is (a few seconds). Nothing was sent; try again in a moment.");
    this.what = what;
  }
  what;
  kind = "not-in-block";
};
var daaForCore = (u) => u.confirmed === false ? UNACCEPTED_DAA_SCORE : u.blockDaaScore;
function assertSettled(pool, others) {
  for (const o of others) {
    if (o.coin.confirmed === false && o.coin.transactionId !== pool.transactionId) throw new NotInBlockYet(o.what);
  }
}

// ../../../kusdt-open/wallet/extension/src/kusdt/build.ts
var MAX_FEE = 300000000n;
var CORE_MIN_CHANGE = 20000000n;
var ABSORB_LIMIT = 5000000n;
var CAP_TRIES = 4;
var UNSETTLED = "The network fee does not settle for this amount: what would come back as change is at the edge of what the network keeps. Change the amount a little and try again. Nothing was sent.";
var COINBASE_MATURITY2 = 1100n;
var feeNeeded = (built, feerate) => built.mass.feeMass * BigInt(Math.ceil(feerate));
var coreUtxo = (u) => ({
  transactionId: u.transactionId,
  index: u.index,
  amount: u.amount,
  scriptPublicKey: u.scriptPublicKey,
  blockDaaScore: daaForCore(u),
  isCoinbase: u.isCoinbase,
  covenantId: u.covenantId
});
var toCoreUtxo = coreUtxo;
async function kasCoins(ctx, addresses) {
  const [utxos, pending, inMempool] = await Promise.all([
    ctx.node.utxos(addresses),
    pendingSet(ctx.network),
    ctx.node.mempoolSpent(addresses).catch(() => /* @__PURE__ */ new Set())
  ]);
  const needDaa = utxos.some((u) => u.isCoinbase);
  const daa = needDaa ? await ctx.node.virtualDaa() : 0n;
  return utxos.filter((u) => u.covenantId === null && isSchnorrP2pk(u.scriptPublicKey)).filter((u) => !pending.has(`${u.transactionId}:${u.index}`) && !inMempool.has(`${u.transactionId}:${u.index}`)).filter((u) => !u.isCoinbase || u.blockDaaScore + COINBASE_MATURITY2 <= daa).sort((a, b) => a.amount === b.amount ? 0 : a.amount > b.amount ? -1 : 1).map((u) => ({ address: u.address, utxo: { transactionId: u.transactionId, index: u.index, amount: u.amount, scriptPublicKey: u.scriptPublicKey, blockDaaScore: u.blockDaaScore, isCoinbase: u.isCoinbase, covenantId: null, confirmed: true } }));
}
function parseBuilt(value, raw) {
  if (!value || typeof value.txid !== "string" || !Array.isArray(value.outputs)) throw new Error("The core gave an unexpected answer.");
  return {
    txid: value.txid,
    fee: toNat(value.fee, "fee"),
    mass: { compute: toBig(value.mass.compute), storage: toBig(value.mass.storage), transient: toBig(value.mass.transient), feeMass: toBig(value.mass.feeMass) },
    covenantId: value.covenantId,
    outputs: value.outputs.map((o) => ({ ...o, value: toNat(o.value, "output value") })),
    raw,
    transaction: rawJsonObject(raw, "transaction")
  };
}
var InsufficientKas = class extends Error {
};
function buildFunded(ctx, signer, coins, command, need, request, feerate, pinned) {
  feerate = Math.ceil(feerate);
  coins = coins.filter((c) => isSchnorrP2pk(c.utxo.scriptPublicKey));
  const cap = fundingCap(command) ?? coins.length;
  const most = Math.min(coins.length, cap);
  let n = 0, sum = 0n;
  const margin = 50000000n;
  while (n < most && sum < need + margin) sum += coins[n++].utxo.amount;
  if (n === 0 && need > 0n) throw new InsufficientKas("There is no KAS to pay for this transaction.");
  const tooFew = () => {
    const all = coins.reduce((t, c) => t + c.utxo.amount, 0n);
    if (coins.length > cap && all > need) return new MergeCoinsFirst(cap, coins.length);
    return new InsufficientKas("Not enough KAS for this transaction and its network fee.");
  };
  let lastError = null;
  const buildOn = (used) => {
    const funding = used.map((c) => {
      const secretKey = signer.secretFor(c.address);
      if (!secretKey) throw new Error("A coin does not belong to this wallet.");
      return { utxo: coreUtxo(c.utxo), secretKey };
    });
    try {
      const { value, raw } = ctx.core.call(command, request(funding, feerate));
      return parseBuilt(value, raw);
    } catch (e) {
      lastError = e;
      const msg = e instanceof CoreError ? e.message : String(e?.message ?? e);
      if (/add funding/.test(msg)) return "more";
      if (/fee did not settle/.test(msg)) return "unsettled";
      throw e instanceof CoreError ? new Error(msg.replace(/^[a-z-]+: /, "")) : e;
    } finally {
      for (const f of funding) f.secretKey = "";
    }
  };
  const absorbedOf = (built) => built.fee - built.mass.feeMass * BigInt(feerate);
  const withinCap = (used, absorbed) => {
    const unused = coins.filter((c) => !used.includes(c));
    const sets = /* @__PURE__ */ new Map();
    const offer = (d, set) => {
      const left = absorbed + d;
      if ((d > 0n || left >= 0n && left <= ABSORB_LIMIT) && !sets.has(d)) sets.set(d, set);
    };
    used.forEach((out, i) => {
      if (pinned?.has(`${out.utxo.transactionId}:${out.utxo.index}`)) return;
      const rest = used.filter((_, j) => j !== i);
      offer(-out.utxo.amount, rest);
      for (const into of unused) offer(into.utxo.amount - out.utxo.amount, [...rest, into]);
    });
    const half = ABSORB_LIMIT / 2n;
    const away = (d) => {
      const x = absorbed + d - half;
      return x < 0n ? -x : x;
    };
    const order = [...sets.keys()].sort((a, b) => a > 0n || b > 0n ? a > b ? -1 : a < b ? 1 : 0 : away(a) < away(b) ? -1 : away(a) > away(b) ? 1 : 0);
    for (const d of order.slice(0, CAP_TRIES)) {
      const built = buildOn(sets.get(d));
      if (typeof built === "object" && absorbedOf(built) <= ABSORB_LIMIT && built.fee <= MAX_FEE) return built;
    }
    throw new MergeCoinsFirst(cap, coins.length, absorbed);
  };
  for (let tries = 0; tries < 12; tries++) {
    const used = coins.slice(0, n);
    const built = buildOn(used);
    if (built === "more") {
      if (n < most) {
        n++;
        continue;
      }
      throw tooFew();
    }
    if (built === "unsettled") {
      if (n < most) {
        n++;
        continue;
      }
      if (coins.length > most) return withinCap(used, CORE_MIN_CHANGE);
      throw new Error(UNSETTLED);
    }
    const absorbed = absorbedOf(built);
    if (absorbed > ABSORB_LIMIT && n < most) {
      n++;
      continue;
    }
    if (absorbed > ABSORB_LIMIT && coins.length > most) return withinCap(used, absorbed);
    if (built.fee > MAX_FEE) throw new Error("The network fee is above the wallet's safety limit. Nothing was sent.");
    return built;
  }
  throw lastError instanceof Error ? lastError : new Error("Could not build the transaction.");
}
function spkOfAddress(address, prefix) {
  const s = scriptForAddress(address, prefix);
  return s.version.toString(16).padStart(4, "0") + bytesToHex(s.script);
}
var sameState = (a, b) => a && toBig(a.amount) === b.amount && a.owner === b.owner && a.ownerScheme === b.ownerScheme && (a.borrowScheme ?? 0) === b.borrowScheme && a.borrowGuard === b.borrowGuard && a.extensionCommitment === b.extensionCommitment;
function checkBuilt(ctx, built, signer, expect) {
  const mine = spkOfAddress(signer.address, ctx.net.prefix);
  const claimed = /* @__PURE__ */ new Set();
  for (const t of expect.tokens) {
    const o = built.outputs[t.index];
    if (!o || !o.token || !sameState(o.token, t.state)) throw new Error("The built transaction does not send what was approved. Nothing was sent.");
    if (o.value !== t.value) throw new Error("A token output carries an unexpected amount of KAS. Nothing was sent.");
    if (o.scriptPublicKey !== scriptOf2(ctx, "KCC20", t.state)) throw new Error("A token output has an unexpected script. Nothing was sent.");
    claimed.add(t.index);
  }
  for (const c of expect.covenant ?? []) {
    const o = built.outputs[c.index];
    if (!o || o.kind !== c.kind) throw new Error("The built transaction has unexpected outputs. Nothing was sent.");
    claimed.add(c.index);
  }
  let change = 0n;
  built.outputs.forEach((o, i) => {
    if (claimed.has(i)) return;
    if (o.scriptPublicKey !== mine) throw new Error("The built transaction pays an address it should not. Nothing was sent.");
    change += o.value;
  });
  if (expect.minChange != null && change < expect.minChange) throw new Error("Less KAS would come back than expected. Nothing was sent.");
  if (built.fee > MAX_FEE) throw new Error("The network fee is above the wallet's safety limit. Nothing was sent.");
}

// ../../../kusdt-open/wallet/extension/src/kusdt/submit.ts
async function submitBuilt(ctx, built, merge = false) {
  let txid;
  try {
    txid = await ctx.node.submit(built.transaction);
  } catch (e) {
    if (e instanceof NodeRejected && nodeHasTransaction(e.said, built.txid)) txid = built.txid;
    else if (e instanceof NoAnswer) {
      await markSpent(ctx.network, inputsOf(built.transaction)).catch(() => {
      });
      await noteBuilt(ctx, built, false).catch(() => {
      });
      throw new MaybeSent(built.txid, merge);
    } else throw e;
  }
  if (txid !== built.txid) throw new Error(`The node reports transaction ${txid}, the wallet built ${built.txid}.`);
  await markSpent(ctx.network, inputsOf(built.transaction));
  await noteBuilt(ctx, built, true).catch(() => {
  });
  return txid;
}
function addressOfSpk(spkHex2, prefix) {
  if (/^0000aa20[0-9a-f]{64}87$/.test(spkHex2)) return p2shAddressOf(spkHex2, prefix);
  const a = addressForScript({ version: parseInt(spkHex2.slice(0, 4), 16), script: hexToBytes(spkHex2.slice(4)) }, prefix);
  if (!a) throw new Error("An output has no address.");
  return a;
}
var sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitForOutput(ctx, built, index, timeoutMs = 9e4) {
  const o = built.outputs[index];
  if (!o) throw new Error("No such output.");
  const address = addressOfSpk(o.scriptPublicKey, ctx.net.prefix);
  const end = Date.now() + timeoutMs;
  for (; ; ) {
    const u = (await ctx.node.utxos([address]).catch(() => [])).find((x) => x.transactionId === built.txid && x.index === index);
    if (u) {
      if (u.scriptPublicKey !== o.scriptPublicKey || u.amount !== o.value) throw new Error("The node reports a different output than the one built.");
      return { transactionId: u.transactionId, index: u.index, amount: u.amount, scriptPublicKey: u.scriptPublicKey, blockDaaScore: u.blockDaaScore, isCoinbase: false, covenantId: u.covenantId, confirmed: true };
    }
    if (Date.now() > end) throw new Error("The transaction was sent but has not been confirmed yet. Check again in a minute.");
    await sleep(1e3);
  }
}
var CONFIRM_WAIT = { ms: 3e4, everyMs: 1e3 };
var outputAddresses = (built, prefix) => [...new Set(built.outputs.map((o) => addressOfSpk(o.scriptPublicKey, prefix)))];
async function lookAt(ctx, txid, addresses, raced) {
  let utxos, daa;
  const inMempool = await ctx.node.inMempool(txid).catch(() => false);
  try {
    utxos = await ctx.node.utxos([.../* @__PURE__ */ new Set([...addresses, raced.address])]);
    daa = await ctx.node.virtualDaa();
  } catch {
    return "unknown";
  }
  if (utxos.some((u) => u.transactionId === txid)) return "confirmed";
  if (inMempool) return "unknown";
  if (utxos.some((u) => `${u.transactionId}:${u.index}` === raced.outpoint)) {
    raced.seen = true;
    if (daa > BigInt(raced.daa)) raced.daa = daa.toString();
    return "unknown";
  }
  return raced.seen && daa > BigInt(raced.daa) ? "gone" : "unknown";
}
async function awaitOutcome(ctx, built, raced, wait = CONFIRM_WAIT) {
  const addresses = outputAddresses(built, ctx.net.prefix);
  const end = Date.now() + wait.ms;
  let gone = 0;
  for (; ; ) {
    const seen = await lookAt(ctx, built.txid, addresses, raced);
    if (seen === "confirmed") return "confirmed";
    gone = seen === "gone" ? gone + 1 : 0;
    if (gone >= 2) return "lost";
    if (Date.now() >= end) return "unknown";
    await sleep(wait.everyMs);
  }
}

// ../../../kusdt-open/wallet/extension/src/kusdt/unconfirmed.ts
var KEY4 = (network) => `kusdt.unconfirmed.${network}`;
var KEEP_MS = 24 * 36e5;
var load3 = async (network) => (await local.get(KEY4(network)) ?? []).filter((w) => Date.now() - w.at < KEEP_MS);
async function noteUnconfirmed(ctx, built, raced) {
  const list = (await load3(ctx.network)).filter((w) => w.txid !== built.txid);
  list.push({ txid: built.txid, inputs: inputsOf(built.transaction), addresses: outputAddresses(built, ctx.net.prefix), raced: { ...raced }, at: Date.now(), gone: 0 });
  await local.set({ [KEY4(ctx.network)]: list.slice(-50) });
}

// ../../../kusdt-open/wallet/extension/src/kusdt/tokens.ts
var MAX_TOKEN_INPUTS = 3;
var MAX_TOKEN_OUTPUTS = 3;
var largestFirst = (a, b) => a.state.amount === b.state.amount ? 0 : a.state.amount > b.state.amount ? -1 : 1;
async function loadTokens(ctx, signer) {
  if (!ctx.api) throw new Error("No coordinator API is set for this network.");
  const known = await knownRecord(ctx.network, signer.ownerHex).catch(() => []);
  let listed2 = [], listedApart = [], fromMemory = false, apiError;
  try {
    const answer = await ctx.api.tokens(signer.ownerHex);
    listed2 = answer.states;
    listedApart = Array.isArray(answer.unread) ? answer.unread : [];
  } catch (e) {
    if (!known.some((k) => k.spentBy === void 0)) throw e;
    fromMemory = true;
    apiError = e?.message || "no answer";
  }
  const { verified, rejected, unread, unreadNoRecord, missing } = await verifyTokenStates(ctx, [...listed2, ...listedApart], signer.ownerHex, known, !fromMemory && listedApart.length === 0 && listed2.length < MAX_LISTED);
  await updateKnown(ctx.network, signer.ownerHex, verified.map((s) => ({ txid: s.utxo.transactionId, index: s.utxo.index, amount: s.state.amount, kas: s.utxo.amount, daa: s.utxo.blockDaaScore })), missing).catch(() => {
  });
  const pending = await pendingSet(ctx.network);
  const free = (s) => !pending.has(`${s.utxo.transactionId}:${s.utxo.index}`);
  const states = verified.filter(free).sort(largestFirst);
  const apart = unread.filter(free).sort(largestFirst);
  return {
    states,
    total: states.reduce((s, x) => s + x.state.amount, 0n),
    rejected,
    unread: apart,
    unreadTotal: apart.reduce((s, x) => s + x.state.amount, 0n),
    unreadNoRecord,
    fromMemory,
    ...apiError !== void 0 && { apiError }
  };
}
function chooseStates(states, amount) {
  if (amount <= 0n) throw new Error("Enter an amount above zero.");
  const sorted = [...states].sort((a, b) => a.state.amount === b.state.amount ? 0 : a.state.amount > b.state.amount ? -1 : 1);
  const picked = [];
  let sum = 0n;
  for (const s of sorted) {
    if (sum >= amount) break;
    picked.push(s);
    sum += s.state.amount;
  }
  if (sum < amount) throw new Error("Not enough kUSDT.");
  return { picked, merges: mergesFor(picked.length) };
}
var mergesFor = (n) => n <= MAX_TOKEN_INPUTS ? 0 : Math.ceil((n - MAX_TOKEN_INPUTS) / (MAX_TOKEN_INPUTS - 1));
var TAG = new TextEncoder().encode("kUSDT/redeem/v1");
function buildTransfer(ctx, signer, coins, args, feerate) {
  if (args.inputs.length < 1 || args.inputs.length > MAX_TOKEN_INPUTS || args.outputs.length < 1 || args.outputs.length > MAX_TOKEN_OUTPUTS) {
    throw new Error("A kUSDT transfer has 1 to 3 inputs and 1 to 3 outputs.");
  }
  const inTotal = args.inputs.reduce((s, i) => s + i.state.amount, 0n);
  const outTotal = args.outputs.reduce((s, o) => s + o.state.amount, 0n);
  if (inTotal !== outTotal) throw new Error("Token inputs and outputs must hold the same amount.");
  const secret = signer.secretFor(signer.address);
  if (!secret) throw new Error("The wallet is locked.");
  const kasIn = args.inputs.reduce((s, i) => s + i.utxo.amount, 0n);
  const kasOut = args.outputs.reduce((s, o) => s + o.value, 0n);
  const built = buildFunded(ctx, signer, coins, "transfer", kasOut - kasIn, (funding, feerate2) => ({
    network: ctx.network,
    feerate: feerate2,
    changeAddress: signer.address,
    funding,
    inputs: args.inputs.map((i) => ({ utxo: toCoreUtxo(i.utxo), state: i.state, secretKey: secret })),
    outputs: args.outputs,
    redeem: args.redeem ?? []
  }), feerate);
  checkBuilt(ctx, built, signer, { tokens: args.outputs.map((o, index) => ({ index, state: o.state, value: o.value })) });
  return built;
}
async function walletCoins(ctx, addresses) {
  return kasCoins(ctx, addresses);
}
async function mergeStates(ctx, signer, kasAddresses, group, onStep, holdFeerate) {
  const total = group.reduce((s, i) => s + i.state.amount, 0n);
  const state = plainState({ ownerScheme: 0, owner: signer.ownerHex }, total);
  const [coins, feerate] = await Promise.all([walletCoins(ctx, kasAddresses), ctx.node.feerate()]);
  holdFeerate?.(feerate);
  const built = buildTransfer(ctx, signer, coins, { inputs: group, outputs: [{ state, value: BigInt(ctx.config.tokenValue) }] }, feerate);
  const txid = await submitBuilt(ctx, built, true);
  onStep?.(txid, built);
  return { utxo: await waitForOutput(ctx, built, 0), state };
}
async function mergeDown(ctx, signer, kasAddresses, picked, onStep, holdFeerate) {
  let list = [...picked];
  while (list.length > MAX_TOKEN_INPUTS) {
    list.sort((a, b) => a.state.amount === b.state.amount ? 0 : a.state.amount > b.state.amount ? -1 : 1);
    const group = list.slice(-MAX_TOKEN_INPUTS);
    const merged = await mergeStates(ctx, signer, kasAddresses, group, onStep, holdFeerate);
    list = [...list.slice(0, list.length - MAX_TOKEN_INPUTS), merged];
  }
  return list;
}
var singleStateOf = (states, amount) => states.filter((s) => s.state.amount >= amount).sort((a, b) => a.state.amount < b.state.amount ? -1 : 1)[0];
async function singleStateFor(ctx, signer, kasAddresses, amount, onStep, holdFeerate) {
  const { states } = await loadTokens(ctx, signer);
  const one = singleStateOf(states, amount);
  if (one) return one;
  let { picked } = chooseStates(states, amount);
  picked = await mergeDown(ctx, signer, kasAddresses, picked, onStep, holdFeerate);
  return picked.length === 1 ? picked[0] : mergeStates(ctx, signer, kasAddresses, picked, onStep, holdFeerate);
}

// ../../../kusdt-open/wallet/extension/src/kusdt/pool.ts
var MAX_POOL_TRIES = 3;
var BPS2 = 10000n;
var SELL_DAA_MARGIN = 10n;
var DAA_PER_SECOND = 10n;
var LOCKED_SHARES = 1000n;
var FEE_KEEP = 30000000n;
var MAX_SWAP_INPUT = 230584300921369n;
var MIN_AGE_PARTS = 720n;
var READY_WAIT_MS = 6e4;
var LOCK_RETRY = { ms: 100, tries: 20 };
var LOCK_NOT_MET = /sequence locks? conditions/i;
function leastClaimOf(pool) {
  if (pool.windowOut <= pool.windowRef * pool.maxOutBps / BPS2 / 2n) return 0n;
  const least = pool.windowLen / MIN_AGE_PARTS;
  return least < 1n ? 1n : least;
}
function leastRemoveClaimOf(pool) {
  return pool.paused ? 0n : leastClaimOf(pool);
}
function poolReadyAt(vp, least = leastClaimOf(vp.pool.state)) {
  if (least === 0n) return 0n;
  if (vp.pool.utxo.confirmed === false || !(vp.pool.utxo.blockDaaScore > 0n)) return null;
  return vp.pool.utxo.blockDaaScore + least;
}
function poolNowDaa(vp, virtualDaa, least = leastClaimOf(vp.pool.state)) {
  const clock = sellNowDaa(vp.pool.state, virtualDaa);
  const at = poolReadyAt(vp, least);
  return at !== null && at > clock && at <= virtualDaa ? at : clock;
}
function quoteBuy(ctx, pool, kasIn) {
  return toBig(ctx.core.call("quote", { kind: "buy", pool, kasIn }).value.tokensOut);
}
function quoteSell(ctx, pool, tokensIn) {
  return toBig(ctx.core.call("quote", { kind: "sell", pool, tokensIn }).value.kasOut);
}
function quoteAdd(ctx, pool, kasIn, tokensIn) {
  return toBig(ctx.core.call("quote", { kind: "add", pool, kasIn, tokensIn }).value.shares);
}
function quoteRemove(ctx, pool, shares) {
  const v = ctx.core.call("quote", { kind: "remove", pool, shares }).value;
  return { kasOut: toBig(v.kasOut), tokensOut: toBig(v.tokensOut) };
}
function minimumFor(quote, slippageBps) {
  if (!Number.isInteger(slippageBps) || slippageBps < 0 || slippageBps > 5e3) throw new Error("Slippage must be between 0 % and 50 %.");
  return quote * (BPS2 - BigInt(slippageBps)) / BPS2;
}
var BelowMinimum = class extends Error {
  constructor(quote, minimum) {
    super("The pool now pays less than the minimum you set. Nothing was sent.");
    this.quote = quote;
    this.minimum = minimum;
  }
  quote;
  minimum;
};
function assertMinimum(out, minimum) {
  if (minimum <= 0n) throw new Error("Set a minimum to receive above zero.");
  if (out < minimum) throw new BelowMinimum(out, minimum);
}
var PoolPaused = class extends Error {
  constructor() {
    super("The pool is paused: swaps and new liquidity are stopped for now, and withdrawals stay open. Nothing was sent.");
  }
};
function assertNotPaused(pool) {
  if (pool.paused) throw new PoolPaused();
}
function sellNowDaa(_pool, virtualDaa) {
  return virtualDaa > SELL_DAA_MARGIN ? virtualDaa - SELL_DAA_MARGIN : 0n;
}
function quoteSellAt(ctx, pool, tokensIn, nowDaa, poolDaa) {
  const v = ctx.core.call("quote", { kind: "sell", pool, tokensIn, nowDaa, ...poolDaa !== void 0 && { poolDaa } }).value;
  const b = v?.breaker;
  if (!b || typeof b !== "object") throw new Error("The core gave no circuit breaker for this sell.");
  return {
    kasOut: toNat(v.kasOut, "sell quote"),
    breaker: { maxKasOut: toNat(b.maxKasOut, "breaker's room"), windowEndsDaa: toNat(b.windowEndsDaa, "breaker's window end"), allowed: b.allowed === true },
    paused: v.paused === true,
    nowDaa
  };
}
function largestSellWithin(ctx, pool, maxKasOut, hi) {
  if (hi > MAX_SWAP_INPUT) hi = MAX_SWAP_INPUT;
  if (hi <= 0n || maxKasOut <= 0n) return 0n;
  if (quoteSell(ctx, pool, hi) <= maxKasOut) return hi;
  let lo = 0n;
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n;
    if (quoteSell(ctx, pool, mid) <= maxKasOut) lo = mid;
    else hi = mid;
  }
  return lo;
}
var windowOver = (windowEndsDaa, nowDaa) => windowEndsDaa <= nowDaa;
var secondsUntilDaa = (daa, nowDaa) => daa > nowDaa ? Number((daa - nowDaa) / DAA_PER_SECOND) : 0;
var BreakerLimit = class extends Error {
  constructor(kasOut, maxKasOut, windowEndsDaa, maxTokensIn) {
    super(maxTokensIn > 0n ? `The pool's circuit breaker lets sells take out only ${fmtKas(maxKasOut, 4)} KAS more until its window ends (DAA ${windowEndsDaa}). Sell at most ${fmtUsdt(maxTokensIn)} kUSDT now. Nothing was sent.` : `The pool's circuit breaker lets no more KAS out through sells until its window ends (DAA ${windowEndsDaa}). Nothing was sent.`);
    this.kasOut = kasOut;
    this.maxKasOut = maxKasOut;
    this.windowEndsDaa = windowEndsDaa;
    this.maxTokensIn = maxTokensIn;
  }
  kasOut;
  maxKasOut;
  windowEndsDaa;
  maxTokensIn;
};
function assertSellFits(ctx, pool, tokensIn, nowDaa, poolDaa) {
  const q = quoteSellAt(ctx, pool, tokensIn, nowDaa, poolDaa);
  if (!q.breaker.allowed) throw new BreakerLimit(q.kasOut, q.breaker.maxKasOut, q.breaker.windowEndsDaa, largestSellWithin(ctx, pool, q.breaker.maxKasOut, tokensIn));
  return q;
}
var QuoteChanged = class extends Error {
  constructor(seen, now) {
    super("The pool moved before this went in, and it now gives less than what you approved. Nothing was sent: check the new numbers and confirm them to go ahead.");
    this.seen = seen;
    this.now = now;
  }
  seen;
  now;
};
function assertNotWorse(seen, now) {
  const worse = typeof seen === "bigint" ? now < seen : now.kasOut < seen.kasOut || now.tokensOut < seen.tokensOut;
  if (worse) throw new QuoteChanged(seen, now);
}
var POOL_WAIT = { ms: 1e3, perDaaMs: 100 };
var NEAR_DAA = 20n;
var sleep2 = (ms) => new Promise((r) => setTimeout(r, ms));
async function freshPool(ctx, tries = 8) {
  if (!ctx.api) throw new Error("No coordinator API is set for this network.");
  for (let n = 1; ; n++) {
    try {
      return await verifyPool(ctx, await ctx.api.pool());
    } catch (e) {
      if (!(e instanceof VerifyError)) throw e;
      const hint = await session.get(POOL_HINT_KEY(ctx));
      if (hint) {
        try {
          return await verifyPool(ctx, hint);
        } catch {
        }
      }
      if (n >= tries) throw e;
      await sleep2(POOL_WAIT.ms);
    }
  }
}
var POOL_HINT_KEY = (ctx) => `kusdt.poolHint.${ctx.network}.${ctx.config.poolId}`;
async function rememberPool(ctx, built) {
  const p = built.outputs[0];
  const r = built.outputs.find((o) => o.kind === "reserve");
  if (!p?.pool || !r?.token) return;
  await session.set({ [POOL_HINT_KEY(ctx)]: { pool: { utxo: { transactionId: built.txid, index: 0 }, state: p.pool }, reserve: { utxo: { transactionId: built.txid, index: r.index }, state: r.token } } });
}
async function nextPool(ctx, than) {
  let vp = than;
  for (let n = 0; n < 8; n++) {
    vp = await freshPool(ctx);
    if (outpoint(vp) !== outpoint(than)) return vp;
    await sleep2(POOL_WAIT.ms);
  }
  return vp;
}
var outpoint = (vp) => `${vp.pool.utxo.transactionId}:${vp.pool.utxo.index}`;
var PoolBusy = class extends Error {
  constructor() {
    super("The pool was spent again before its last state was old enough to build on (a few seconds). Nothing was sent; try again.");
  }
};
async function readyPool(ctx, vp, waitMs = READY_WAIT_MS, leastOf = leastClaimOf) {
  const until = Date.now() + waitMs;
  for (; ; ) {
    const at = poolReadyAt(vp, leastOf(vp.pool.state));
    const virtualDaa = await ctx.node.virtualDaa();
    if (at !== null && at <= virtualDaa) return vp;
    if (Date.now() >= until) throw new PoolBusy();
    if (at !== null && at - virtualDaa <= NEAR_DAA) {
      await sleep2(Number(at - virtualDaa) * POOL_WAIT.perDaaMs);
      continue;
    }
    await sleep2(POOL_WAIT.ms);
    vp = await freshPool(ctx);
  }
}
var PoolHeld = class extends Error {
  constructor(txid) {
    super(`The Kaspa node this wallet uses is holding a transaction that spends the pool and that no block can take (${txid}). Until the node drops it (up to 24 hours) or another pool transaction is confirmed, it refuses every trade and every deposit or withdrawal of liquidity. Nothing was sent, and your funds are where they were. Try again later, or set another Kaspa node in Settings.`);
    this.txid = txid;
  }
  txid;
};
var corePoolUtxo = (u) => {
  if (u.heldBy) throw new PoolHeld(u.heldBy);
  return toCoreUtxo(u);
};
var LostRace = class extends Error {
  constructor(txid, own) {
    super("Another transaction reached the pool first, so this one did not go through. Nothing left your wallet; try again.");
    this.txid = txid;
    this.own = own;
  }
  txid;
  own;
};
async function sendToPool(ctx, built, vp) {
  const u = vp.pool.utxo;
  const raced = {
    outpoint: `${u.transactionId}:${u.index}`,
    address: p2shAddressOf(u.scriptPublicKey, ctx.net.prefix),
    // Seen in the UTXO set at the build (not only in the mempool), at its own acceptance score at the least.
    seen: u.confirmed !== false,
    daa: (u.confirmed !== false ? u.blockDaaScore : 0n).toString()
  };
  const txid = await submitBuilt(ctx, built);
  const outcome = await awaitOutcome(ctx, built, raced);
  if (outcome === "lost") {
    const inputs = inputsOf(built.transaction);
    await releaseSpent(ctx.network, inputs);
    await restoreSpent(ctx.network, txid).catch(() => {
    });
    const pools = /* @__PURE__ */ new Set([raced.outpoint, ...vp.reserve ? [`${vp.reserve.utxo.transactionId}:${vp.reserve.utxo.index}`] : []]);
    throw new LostRace(txid, inputs.filter((i) => !pools.has(i)));
  }
  await rememberPool(ctx, built);
  if (outcome === "unknown") await noteUnconfirmed(ctx, built, raced).catch(() => {
  });
  return { txid, confirmed: outcome === "confirmed" };
}
var lostFirst = (coins, lost) => {
  const was = new Set(lost.flat());
  const of = (c) => `${c.utxo.transactionId}:${c.utxo.index}`;
  return [...coins.filter((c) => was.has(of(c))), ...coins.filter((c) => !was.has(of(c)))];
};
function assertReplaces(built, lost) {
  const spends = new Set(inputsOf(built.transaction));
  if (!lost.every((own) => own.some((o) => spends.has(o)))) {
    throw new Error("An earlier try lost the race for the pool, and the wallet could not build the next one on the same coins. Nothing more was sent; try again.");
  }
}
async function withFreshPool(ctx, attempt, tries = MAX_POOL_TRIES, first) {
  let vp = first ?? await freshPool(ctx);
  let lockRetries = 0;
  const lost = [];
  for (let n = 1; ; n++) {
    try {
      return await attempt(vp, n, lost);
    } catch (e) {
      if (e instanceof LostRace) {
        lost.push(e.own);
        if (n >= tries) throw e;
        const next2 = await nextPool(ctx, vp);
        if (outpoint(next2) === outpoint(vp)) throw e;
        vp = next2;
        continue;
      }
      if (e instanceof NodeRejected && LOCK_NOT_MET.test(e.said) && lockRetries < LOCK_RETRY.tries) {
        lockRetries++;
        n--;
        await sleep2(LOCK_RETRY.ms);
        const again = await freshPool(ctx).catch(() => null);
        if (again && outpoint(again) === outpoint(vp)) vp = again;
        continue;
      }
      if (!(e instanceof NodeRejected) || n >= tries) {
        if (e instanceof NodeRejected) throw new Error(`The pool kept changing while the wallet tried (${tries} times). Nothing was sent; try again.`);
        throw e;
      }
      const next = await nextPool(ctx, vp);
      if (outpoint(next) === outpoint(vp)) throw e;
      vp = next;
    }
  }
}
function buildBuy(ctx, signer, vp, coins, kasIn, tokensOut, feerate, nowDaa, pinned) {
  const tokenValue = BigInt(ctx.config.tokenValue);
  const bought = plainState({ ownerScheme: 0, owner: signer.ownerHex }, tokensOut);
  assertSettled(vp.pool.utxo, [{ coin: vp.reserve.utxo, what: "coin" }]);
  const built = buildFunded(ctx, signer, coins, "pool-buy", kasIn + tokenValue, (funding, feerate2) => ({
    network: ctx.network,
    feerate: feerate2,
    changeAddress: signer.address,
    funding,
    pool: { utxo: corePoolUtxo(vp.pool.utxo), state: vp.pool.state },
    reserve: { utxo: toCoreUtxo(vp.reserve.utxo), state: vp.reserve.state },
    kasIn,
    tokensOut,
    buyer: signer.ownerHex,
    tokenValue,
    nowDaa
  }), feerate, pinned);
  checkBuilt(ctx, built, signer, { tokens: [{ index: 2, state: bought, value: tokenValue }], covenant: [{ index: 0, kind: "pool" }, { index: 1, kind: "reserve" }] });
  return built;
}
var SELL_FEE_MASS = 82000n;
var POOL_FEE_MASS = 80000n;
var poolFeeAbout = (feerate) => POOL_FEE_MASS * BigInt(Math.ceil(feerate));
var feerateCap = (shown) => Math.ceil(Math.ceil(shown) * 3 / 2);
var PoolFeeAboveShown = class extends Error {
  constructor(feerate, shown) {
    super(`The Kaspa node now asks ${feerate} sompi a gram for the network fee, more than half as much again as the ${shown} shown (about ${fmtKas(poolFeeAbout(feerate), 4)} KAS now), so nothing was sent. Check the new figure and try again.`);
    this.feerate = feerate;
    this.shown = shown;
  }
  feerate;
  shown;
};
function assertFeerateShown(feerate, shown) {
  if (shown == null) return;
  if (Math.ceil(feerate) > feerateCap(shown)) throw new PoolFeeAboveShown(Math.ceil(feerate), Math.ceil(shown));
}
var PoolFeeTakesChange = class extends Error {
  constructor(fee, lost, shown) {
    super(`This would pay ${fmtKas(fee, 4)} KAS to the network, not the about ${fmtKas(shown, 4)} KAS shown: ${fmtKas(lost, 4)} KAS of it is change too small for the network to keep. Nothing was sent. Change the amount a little, so that more of it comes back to you as change.`);
    this.fee = fee;
    this.lost = lost;
    this.shown = shown;
  }
  fee;
  lost;
  shown;
  kind = "fee-takes-change";
};
function assertChangeKept(built, feerate, shown, accepted) {
  if (shown == null) return;
  const lost = built.fee - feeNeeded(built, feerate);
  if (lost <= ABSORB_LIMIT || accepted != null && built.fee <= accepted) return;
  throw new PoolFeeTakesChange(built.fee, lost, poolFeeAbout(shown));
}
function poolFeeShareText(feeAbout, kas) {
  if (feeAbout * 10n <= kas) return null;
  return `The network fee is about ${fmtKas(feeAbout, 4)} KAS, more than a tenth of the ${fmtKas(kas, 4)} KAS this moves. The Kaspa node asks a high feerate right now: approve only if that is worth it to you.`;
}
var SaleLeavesNothing = class extends Error {
  constructor(kasOut, fee) {
    super(fee >= kasOut ? `The network fee (about ${fmtKas(fee, 4)} KAS now) is more than the ${fmtKas(kasOut, 4)} KAS this sale brings. Nothing was sent: sell more, or try again when the network is less busy.` : `This sale brings ${fmtKas(kasOut, 4)} KAS, and all of it would go to the network fee: after the fee (about ${fmtKas(fee, 4)} KAS) less than 0.2 KAS is left, which the network does not keep as change, and this wallet holds no other KAS to add to it. Nothing was sent: sell more, sell all of your kUSDT, or get some KAS first.`);
    this.kasOut = kasOut;
    this.fee = fee;
  }
  kasOut;
  fee;
};
function assertSaleLeavesSomething(kasOut, fee, other, whole, stateKas) {
  if (fee >= kasOut) throw new SaleLeavesNothing(kasOut, fee);
  if (kasOut - fee + other + (whole ? stateKas : 0n) < CORE_MIN_CHANGE) throw new SaleLeavesNothing(kasOut, fee);
}
function buildSell(ctx, signer, vp, coins, payer, tokensIn, kasOut, feerate, nowDaa) {
  const tokenValue = BigInt(ctx.config.tokenValue);
  const secret = signer.secretFor(signer.address);
  if (!secret) throw new Error("The wallet is locked.");
  const all = tokensIn === payer.state.amount;
  assertSettled(vp.pool.utxo, [{ coin: vp.reserve.utxo, what: "coin" }, { coin: payer.utxo, what: "token" }]);
  const built = buildFunded(ctx, signer, coins, "pool-sell", all ? 0n : tokenValue - payer.utxo.amount, (funding, feerate2) => ({
    network: ctx.network,
    feerate: feerate2,
    changeAddress: signer.address,
    funding,
    pool: { utxo: corePoolUtxo(vp.pool.utxo), state: vp.pool.state },
    reserve: { utxo: toCoreUtxo(vp.reserve.utxo), state: vp.reserve.state },
    payer: { utxo: toCoreUtxo(payer.utxo), state: payer.state, secretKey: secret },
    tokensIn,
    kasOut,
    tokenValue,
    nowDaa
  }), feerate);
  const tokens = all ? [] : [{ index: 2, state: { ...payer.state, amount: payer.state.amount - tokensIn }, value: tokenValue }];
  const need = feeNeeded(built, feerate);
  if (built.fee > need || need >= kasOut) throw new SaleLeavesNothing(kasOut, need);
  checkBuilt(ctx, built, signer, { tokens, covenant: [{ index: 0, kind: "pool" }, { index: 1, kind: "reserve" }], minChange: kasOut - need });
  return built;
}
async function swapCheck(ctx, vp, args) {
  const pool = openedPool(vp);
  assertNotPaused(pool.pool.state);
  const nowDaa = poolNowDaa(pool, await ctx.node.virtualDaa());
  let out;
  if (args.side === "buy") out = quoteBuy(ctx, pool.pool.state, args.amountIn);
  else out = assertSellFits(ctx, pool.pool.state, args.amountIn, nowDaa, pool.pool.utxo.blockDaaScore).kasOut;
  assertMinimum(out, args.minOut);
  assertNotWorse(args.quoted, out);
  return { pool, out, nowDaa };
}
async function swap(ctx, signer, kasAddresses, args, onStep) {
  if (args.amountIn <= 0n) throw new Error("Enter an amount above zero.");
  if (args.amountIn > MAX_SWAP_INPUT) throw new Error("That is more than one swap can take.");
  assertMinimum(args.minOut, args.minOut);
  if (args.side === "sell" && args.minOut < CORE_MIN_CHANGE) throw new Error("Sell enough kUSDT to receive at least 0.2 KAS.");
  const first = await freshPool(ctx);
  const checked = await swapCheck(ctx, first, args);
  if (args.side === "sell") {
    const [coins, feerate, held] = await Promise.all([walletCoins(ctx, kasAddresses), ctx.node.feerate(), loadTokens(ctx, signer)]);
    const whole = held.states.find((s) => s.state.amount === args.amountIn);
    assertSaleLeavesSomething(checked.out, SELL_FEE_MASS * BigInt(Math.ceil(feerate)), coins.reduce((t, c) => t + c.utxo.amount, 0n), !!whole, whole?.utxo.amount ?? 0n);
  }
  const payer = args.side === "sell" ? await singleStateFor(ctx, signer, kasAddresses, args.amountIn, onStep, (feerate) => assertFeerateShown(feerate, args.shownFeerate)) : null;
  return withFreshPool(ctx, async (vp, tries, lost) => {
    const { pool, out, nowDaa } = await swapCheck(ctx, await readyPool(ctx, vp), args);
    const [coins, feerate] = await Promise.all([walletCoins(ctx, kasAddresses), ctx.node.feerate()]);
    const built = args.side === "buy" ? buildBuy(ctx, signer, pool, lostFirst(coins, lost), args.amountIn, out, feerate, nowDaa, new Set(lost.flat())) : buildSell(ctx, signer, pool, coins, payer, args.amountIn, out, feerate, nowDaa);
    assertFeerateShown(feerate, args.shownFeerate);
    assertChangeKept(built, feerate, args.shownFeerate, args.acceptedFee);
    assertReplaces(built, lost);
    const { txid, confirmed } = await sendToPool(ctx, built, pool);
    return { txid, amountOut: out, tries, built, confirmed };
  }, MAX_POOL_TRIES, payer ? void 0 : first);
}
var POSITIONS_KEY = (network) => `kusdt.positions.${network}`;
async function recordedPositions(network) {
  return await local.get(POSITIONS_KEY(network)) ?? [];
}
async function savePositions(network, list) {
  await local.set({ [POSITIONS_KEY(network)]: list });
}
async function recordPosition(ctx, signer, txid, shares) {
  const list = await recordedPositions(ctx.network);
  list.push({ txid, index: 1, shares: shares.toString(), owner: signer.ownerHex, tokenCovid: ctx.config.covenantId, at: Date.now() });
  await savePositions(ctx.network, list);
}
async function loadPositions(ctx, signer) {
  const candidates = /* @__PURE__ */ new Map();
  const positionValue = BigInt(ctx.config.positionValue);
  if (ctx.api) {
    try {
      const answer = await ctx.api.positions(signer.ownerHex);
      for (const p of [...answer.positions, ...Array.isArray(answer.unread) ? answer.unread : []].slice(0, MAX_LISTED)) {
        const s = p?.state;
        const txid = p?.utxo?.transactionId, index = p?.utxo?.index;
        if (!isHex32(txid) || !Number.isInteger(index) || s?.owner !== signer.ownerHex || s?.tokenCovid !== ctx.config.covenantId) continue;
        let shares;
        try {
          shares = toNat(s.shares, "shares");
        } catch {
          continue;
        }
        if (shares <= 0n) continue;
        let kas = positionValue;
        try {
          kas = toNat(p.utxo.amount, "position value");
        } catch {
        }
        candidates.set(`${txid}:${index}`, { txid, index, state: { tokenCovid: s.tokenCovid, shares, owner: s.owner }, at: 0, kas });
      }
    } catch {
    }
  }
  for (const r of await recordedPositions(ctx.network)) {
    if (r.owner !== signer.ownerHex || r.tokenCovid !== ctx.config.covenantId) continue;
    const id = `${r.txid}:${r.index}`;
    const known = candidates.get(id);
    if (known) known.at = r.at;
    else candidates.set(id, { txid: r.txid, index: r.index, state: { tokenCovid: r.tokenCovid, shares: BigInt(r.shares), owner: r.owner }, at: r.at, kas: positionValue });
  }
  const out = [];
  for (const [id, c] of candidates) {
    const located = await verifyPosition(ctx, c.txid, c.index, c.state).catch(() => null);
    if (located === UNREAD) {
      out.push({ id, at: c.at, unread: true, located: { state: c.state, utxo: { transactionId: c.txid, index: c.index, amount: c.kas, scriptPublicKey: scriptOf2(ctx, "Position", c.state), blockDaaScore: 0n, isCoinbase: false, covenantId: ctx.config.poolId, confirmed: true, unchecked: true } } });
    } else if (located) out.push({ id, located, at: c.at });
  }
  return out;
}
var MAX_ADD_RATIO_DRIFT_BPS = 500n;
function addRatioProblem(pool, kasIn, tokensIn) {
  const a = kasIn * pool.tokenReserve, b = tokensIn * pool.kasReserve;
  const [hi, lo] = a > b ? [a, b] : [b, a];
  if ((hi - lo) * 10000n <= hi * MAX_ADD_RATIO_DRIFT_BPS) return null;
  return `These amounts are more than ${MAX_ADD_RATIO_DRIFT_BPS / 100n} % off the pool's ratio: what is above the ratio would go to the pool for nothing. Nothing was sent.`;
}
function trimToShares(pool, kasIn, tokensIn) {
  const { kasReserve: x, tokenReserve: y, totalShares: s } = pool;
  if (x <= 0n || y <= 0n || s <= 0n) return { kasIn, tokensIn, shares: 0n };
  const buys = (k2, t2) => {
    const a = k2 * s / x, b = t2 * s / y;
    return a < b ? a : b;
  };
  const target = buys(kasIn, tokensIn);
  if (target <= 0n) return { kasIn, tokensIn, shares: 0n };
  const k = (target * x + s - 1n) / s, t = (target * y + s - 1n) / s;
  return { kasIn: k, tokensIn: t, shares: buys(k, t) };
}
var isEmptied = (s) => s.totalShares === LOCKED_SHARES;
function addCheck(ctx, vp, args, ownerHex) {
  if (vp.pool.state.totalShares === 0n) throw new Error("The pool has no liquidity yet: open it first.");
  if (isEmptied(vp.pool.state) && ownerHex !== void 0 && ownerHex !== vp.pool.state.admin) {
    throw new Error("Every provider has left the pool: only its admin can deposit into it first, which starts its sell cap again. Nothing was sent.");
  }
  const pool = openedPool(vp);
  assertNotPaused(pool.pool.state);
  const off = addRatioProblem(pool.pool.state, args.kasIn, args.tokensIn);
  if (off) throw new Error(off);
  const used = trimToShares(pool.pool.state, args.kasIn, args.tokensIn);
  const shares = quoteAdd(ctx, pool.pool.state, used.kasIn, used.tokensIn);
  if (shares !== used.shares) throw new Error("The deposit could not be trimmed to the pool ratio. Nothing was sent.");
  assertMinimum(shares, args.minShares);
  assertNotWorse(args.quoted, shares);
  return { pool, shares, kasIn: used.kasIn, tokensIn: used.tokensIn };
}
async function addLiquidity(ctx, signer, kasAddresses, args, onStep) {
  if (args.kasIn <= 0n || args.tokensIn <= 0n) throw new Error("Add some KAS and some kUSDT.");
  assertMinimum(args.minShares, args.minShares);
  addCheck(ctx, await freshPool(ctx), args, signer.ownerHex);
  const provider = await singleStateFor(ctx, signer, kasAddresses, args.tokensIn, onStep, (feerate) => assertFeerateShown(feerate, args.shownFeerate));
  const secret = signer.secretFor(signer.address);
  if (!secret) throw new Error("The wallet is locked.");
  const tokenValue = BigInt(ctx.config.tokenValue), positionValue = BigInt(ctx.config.positionValue);
  const result = await withFreshPool(ctx, async (vp, _n, lost) => {
    const { pool, shares, kasIn, tokensIn } = addCheck(ctx, await readyPool(ctx, vp), args, signer.ownerHex);
    const [coins, feerate, virtualDaa] = await Promise.all([walletCoins(ctx, kasAddresses), ctx.node.feerate(), ctx.node.virtualDaa()]);
    const nowDaa = poolNowDaa(pool, virtualDaa);
    assertSettled(pool.pool.utxo, [{ coin: pool.reserve.utxo, what: "coin" }, { coin: provider.utxo, what: "token" }]);
    const built = buildFunded(ctx, signer, coins, "pool-add", kasIn + positionValue + tokenValue - provider.utxo.amount, (funding, feerate2) => ({
      network: ctx.network,
      feerate: feerate2,
      changeAddress: signer.address,
      funding,
      pool: { utxo: corePoolUtxo(pool.pool.utxo), state: pool.pool.state },
      reserve: { utxo: toCoreUtxo(pool.reserve.utxo), state: pool.reserve.state },
      provider: { utxo: toCoreUtxo(provider.utxo), state: provider.state, secretKey: secret },
      kasIn,
      tokensIn,
      shares,
      positionOwner: signer.ownerHex,
      tokenValue,
      positionValue,
      nowDaa,
      ...isEmptied(pool.pool.state) && { adminSecretKey: secret }
    }), feerate);
    const pos = built.outputs[1]?.position;
    if (!pos || pos.owner !== signer.ownerHex || toBig(pos.shares) !== shares || pos.tokenCovid !== ctx.config.covenantId || built.outputs[1].value !== positionValue) {
      throw new Error("The built position is not the one approved. Nothing was sent.");
    }
    checkBuilt(ctx, built, signer, {
      tokens: [{ index: 3, state: { ...provider.state, amount: provider.state.amount - tokensIn }, value: tokenValue }],
      covenant: [{ index: 0, kind: "pool" }, { index: 1, kind: "position" }, { index: 2, kind: "reserve" }]
    });
    assertFeerateShown(feerate, args.shownFeerate);
    assertChangeKept(built, feerate, args.shownFeerate, args.acceptedFee);
    assertReplaces(built, lost);
    const { txid, confirmed } = await sendToPool(ctx, built, pool);
    return { txid, shares, kasIn, tokensIn, built, confirmed };
  });
  await recordPosition(ctx, signer, result.txid, result.shares);
  return result;
}
function removeCheck(ctx, vp, shares, args) {
  const pool = openedPool(vp);
  const { kasOut, tokensOut } = quoteRemove(ctx, pool.pool.state, shares);
  if (kasOut < args.minKas || tokensOut < args.minTokens) throw new BelowMinimum(kasOut, args.minKas);
  assertNotWorse(args.quoted, { kasOut, tokensOut });
  return { pool, kasOut, tokensOut };
}
async function removeLiquidity(ctx, signer, kasAddresses, args) {
  const pos = (await loadPositions(ctx, signer)).find((p) => p.id === args.position);
  if (!pos) throw new Error("That position was not found in this wallet.");
  const secret = signer.secretFor(signer.address);
  if (!secret) throw new Error("The wallet is locked.");
  const tokenValue = BigInt(ctx.config.tokenValue);
  return withFreshPool(ctx, async (vp, _n, lost) => {
    const { pool, kasOut, tokensOut } = removeCheck(ctx, await readyPool(ctx, vp, READY_WAIT_MS, leastRemoveClaimOf), pos.located.state.shares, args);
    const [coins, feerate, virtualDaa] = await Promise.all([walletCoins(ctx, kasAddresses), ctx.node.feerate(), ctx.node.virtualDaa()]);
    const nowDaa = poolNowDaa(pool, virtualDaa, leastRemoveClaimOf(pool.pool.state));
    const received = plainState({ ownerScheme: 0, owner: signer.ownerHex }, tokensOut);
    assertSettled(pool.pool.utxo, [{ coin: pool.reserve.utxo, what: "coin" }, { coin: pos.located.utxo, what: "position" }]);
    const built = buildFunded(ctx, signer, coins, "pool-remove", tokenValue - pos.located.utxo.amount - kasOut, (funding, feerate2) => ({
      network: ctx.network,
      feerate: feerate2,
      changeAddress: signer.address,
      funding,
      pool: { utxo: corePoolUtxo(pool.pool.utxo), state: pool.pool.state },
      reserve: { utxo: toCoreUtxo(pool.reserve.utxo), state: pool.reserve.state },
      position: { utxo: toCoreUtxo(pos.located.utxo), state: pos.located.state },
      positionSecretKey: secret,
      kasOut,
      tokensOut,
      receiver: signer.ownerHex,
      tokenValue,
      nowDaa
    }), feerate);
    checkBuilt(ctx, built, signer, {
      tokens: [{ index: 2, state: received, value: tokenValue }],
      covenant: [{ index: 0, kind: "pool" }, { index: 1, kind: "reserve" }],
      // As for a sale: against the fee its size needs, so change left to the fee never counts as paid for.
      minChange: kasOut - feeNeeded(built, feerate)
    });
    assertFeerateShown(feerate, args.shownFeerate);
    assertChangeKept(built, feerate, args.shownFeerate, args.acceptedFee);
    assertReplaces(built, lost);
    const { txid, confirmed } = await sendToPool(ctx, built, pool);
    return { txid, kasOut, tokensOut, built, confirmed };
  });
}
function lockedKasFor(ctx, kind) {
  const tokenValue = BigInt(ctx.config.tokenValue), positionValue = BigInt(ctx.config.positionValue);
  return kind === "buy" ? tokenValue : kind === "add" ? positionValue : positionValue + tokenValue;
}
function maxKasIn(ctx, kind, spendable) {
  const left = spendable - lockedKasFor(ctx, kind) - FEE_KEEP;
  return left > 0n ? left : 0n;
}
function maxBuyAcceptedFee(ctx, side, amountIn, spendable) {
  if (side !== "buy" || spendable == null) return void 0;
  const max = maxKasIn(ctx, "buy", spendable);
  return max > 0n && amountIn >= max ? FEE_KEEP : void 0;
}

// src/entry.ts
setCoreLoader(() => makeCore(wasm));
var nodes = /* @__PURE__ */ new Map();
var nodeFor = (network) => {
  let n = nodes.get(network);
  if (!n) {
    n = new KaspaNodeClient(network, "");
    nodes.set(network, n);
  }
  return n;
};
async function ctxFor(w) {
  if (w.network !== "mainnet" && w.network !== "testnet-10") throw new Error("KaPay trades only on mainnet and testnet-10.");
  const config = { ...DEFAULTS[w.network], apiUrl: w.apiUrl || DEFAULTS[w.network].apiUrl };
  return {
    core: await getCore(),
    node: nodeFor(w.network),
    api: new CoordinatorClient(config.apiUrl),
    network: w.network,
    net: KASPA_NETWORKS[w.network],
    config
  };
}
function signerFor(w) {
  return {
    address: w.address,
    ownerHex: w.ownerHex,
    secretFor: (address) => address === w.address && w.secret ? w.secret : null
  };
}
var nat = (v, what) => {
  if (typeof v === "number" && Number.isSafeInteger(v) && v >= 0) return BigInt(v);
  if (typeof v === "string" && /^\d{1,30}$/.test(v)) return BigInt(v);
  throw Object.assign(new Error(`${what} must be a whole number.`), { code: -32602 });
};
var json = (value) => JSON.stringify(value, (_k, v) => typeof v === "bigint" ? v.toString() : v);
var failure = (e) => {
  const error = e instanceof Error ? e.message : String(e);
  const code = e?.code;
  return { error, ...typeof code === "number" ? { code } : {}, ...e instanceof MaybeSent ? { maybeSent: true } : {} };
};
async function prepareSwap(ctx, w, p) {
  if (p?.side !== "buy" && p?.side !== "sell") throw Object.assign(new Error('side must be "buy" or "sell".'), { code: -32602 });
  const amountIn = nat(p.amountIn, "amountIn"), minOut = nat(p.minOut, "minOut");
  const [vp, feerate] = await Promise.all([freshPool(ctx), ctx.node.feerate()]);
  if (!vp.reserve || vp.pool.state.totalShares === 0n) throw new Error("The pool has no liquidity yet, so there is nothing to swap with.");
  const state = vp.pool.state;
  const spendable = p.side === "buy" ? await kasBalance(ctx.node, ctx.network, [w.address]).then((k) => k.spendable, () => null) : null;
  const acceptedFee = maxBuyAcceptedFee(ctx, p.side, amountIn, spendable);
  let quote, breaker = null;
  if (p.side === "buy") quote = quoteBuy(ctx, state, amountIn);
  else {
    const nowDaa = sellNowDaa(state, await ctx.node.virtualDaa());
    const s = quoteSellAt(ctx, state, amountIn, nowDaa, vp.pool.utxo.blockDaaScore);
    quote = s.kasOut;
    if (!s.breaker.allowed) {
      const fit = largestSellWithin(ctx, state, s.breaker.maxKasOut, amountIn);
      breaker = JSON.stringify({ maxKasOut: s.breaker.maxKasOut.toString(), fit: fit.toString(), seconds: windowOver(s.breaker.windowEndsDaa, nowDaa) ? 0 : secondsUntilDaa(s.breaker.windowEndsDaa, nowDaa) });
    }
  }
  const feeAbout = poolFeeAbout(feerate);
  return {
    kind: "swap",
    side: p.side,
    amountIn,
    minOut,
    quote,
    feeAbout,
    feerate,
    acceptedFee: acceptedFee ?? null,
    tokenValue: BigInt(ctx.config.tokenValue),
    paused: state.paused,
    breaker,
    belowMinimum: quote < minOut,
    feeShare: poolFeeShareText(feeAbout, p.side === "buy" ? amountIn : quote) !== null,
    blocked: state.paused || breaker !== null || quote < minOut
  };
}
async function prepareAdd(ctx, p) {
  const kasIn = nat(p?.kasIn, "kasIn"), tokensIn = nat(p?.tokensIn, "tokensIn");
  const [vp, feerate] = await Promise.all([freshPool(ctx), ctx.node.feerate()]);
  if (!vp.reserve || vp.pool.state.totalShares === 0n) throw new Error("The pool has no liquidity yet.");
  const used = trimToShares(vp.pool.state, kasIn, tokensIn);
  const quote = quoteAdd(ctx, vp.pool.state, used.kasIn, used.tokensIn);
  const off = addRatioProblem(vp.pool.state, kasIn, tokensIn);
  const feeAbout = poolFeeAbout(feerate);
  return {
    kind: "add",
    kasIn: used.kasIn,
    tokensIn: used.tokensIn,
    askedKasIn: kasIn,
    askedTokensIn: tokensIn,
    quote,
    feeAbout,
    feerate,
    positionValue: BigInt(ctx.config.positionValue),
    tokenValue: BigInt(ctx.config.tokenValue),
    paused: vp.pool.state.paused,
    offRatio: off !== null,
    feeShare: poolFeeShareText(feeAbout, used.kasIn) !== null,
    blocked: vp.pool.state.paused || off !== null
  };
}
async function prepareRemove(ctx, w, p) {
  if (typeof p?.position !== "string") throw Object.assign(new Error('position must be a "txid:index" string.'), { code: -32602 });
  const pos = (await loadPositions(ctx, signerFor(w))).find((x) => x.id === p.position);
  if (!pos) throw new Error("That position isn't one of this address's.");
  const [vp, feerate] = await Promise.all([freshPool(ctx), ctx.node.feerate()]);
  const q = quoteRemove(ctx, vp.pool.state, pos.located.state.shares);
  const feeAbout = poolFeeAbout(feerate);
  return {
    kind: "remove",
    position: p.position,
    shares: pos.located.state.shares,
    kasOut: q.kasOut,
    tokensOut: q.tokensOut,
    feeAbout,
    feerate,
    unread: pos.unread === true,
    feeShare: poolFeeShareText(feeAbout, q.kasOut) !== null,
    blocked: false
  };
}
async function prepare(r) {
  const ctx = await ctxFor(r.wallet);
  if (r.method === "kusdt_swap") return prepareSwap(ctx, r.wallet, r.params);
  if (r.method === "kusdt_addLiquidity") return prepareAdd(ctx, r.params);
  if (r.method === "kusdt_removeLiquidity") return prepareRemove(ctx, r.wallet, r.params);
  throw Object.assign(new Error("Unsupported request."), { code: 4200 });
}
async function execute(r) {
  const w = r.wallet;
  if (!w.secret) throw new Error("No key was given for this address.");
  const ctx = await ctxFor(w);
  const signer = signerFor(w);
  const steps = [];
  const onStep = (txid) => {
    steps.push(txid);
  };
  if (typeof r.shownFeerate !== "number" || !(r.shownFeerate > 0)) throw new Error("No network fee was shown for this.");
  const feerate = r.shownFeerate;
  try {
    if (r.method === "kusdt_swap") {
      const p = r.params;
      const amountIn = nat(p.amountIn, "amountIn"), minOut = nat(p.minOut, "minOut"), quoted2 = nat(r.quoted, "quoted");
      const acceptedFee = r.acceptedFee != null ? nat(r.acceptedFee, "acceptedFee") : void 0;
      const res = await swap(ctx, signer, [w.address], { side: p.side, amountIn, minOut, quoted: quoted2, shownFeerate: feerate, acceptedFee }, onStep);
      return { result: { txid: res.txid, amountOut: res.amountOut.toString(), confirmed: res.confirmed }, fee: res.built.fee, steps, inputs: inputsOf(res.built.transaction) };
    }
    if (r.method === "kusdt_addLiquidity") {
      const kasIn = nat(r.params.kasIn, "kasIn"), tokensIn = nat(r.params.tokensIn, "tokensIn"), quoted2 = nat(r.quoted, "quoted");
      const res = await addLiquidity(ctx, signer, [w.address], { kasIn, tokensIn, minShares: minimumFor(quoted2, 100), quoted: quoted2, shownFeerate: feerate }, onStep);
      return { result: { txid: res.txid, shares: res.shares.toString(), confirmed: res.confirmed }, fee: res.built.fee, steps, inputs: inputsOf(res.built.transaction) };
    }
    if (r.method === "kusdt_removeLiquidity") {
      const q = { kasOut: nat(r.quoted?.kasOut, "kasOut"), tokensOut: nat(r.quoted?.tokensOut, "tokensOut") };
      const res = await removeLiquidity(ctx, signer, [w.address], { position: r.params.position, minKas: minimumFor(q.kasOut, 100), minTokens: minimumFor(q.tokensOut, 100), quoted: q, shownFeerate: feerate });
      return { result: { txid: res.txid, confirmed: res.confirmed }, fee: res.built.fee, steps, inputs: inputsOf(res.built.transaction) };
    }
  } catch (e) {
    if (e instanceof QuoteChanged) return { requote: e.now, seen: e.seen, steps };
    throw e;
  }
  throw Object.assign(new Error("Unsupported request."), { code: 4200 });
}
globalThis.kapayWallet = Object.freeze({
  prepare: (text) => prepare(JSON.parse(text)).then(json, (e) => json(failure(e))),
  execute: (text) => execute(JSON.parse(text)).then(json, (e) => json(failure(e)))
});
