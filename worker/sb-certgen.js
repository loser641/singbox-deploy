// sing-box 证书生成服务
//
// GET /generate                        → 默认 CN/SAN=www.bing.com（兼容旧版脚本）
// GET /generate?d=<base64url(域名/IP)> → 为指定域名或 IP 生成证书
//      d 也可以直接传明文域名/IP（便于 curl 手动测试）
// GET /health                          → "ok"
//
// 只接受合法的 DNS 主机名 / IPv4 / IPv6，其余一律 400。
// 纯 WebCrypto 实现，无任何依赖，不落盘、不缓存私钥。

const DEFAULT_CN = "www.bing.com";
const VALID_DAYS = 36500; // 100 年
const MAX_NAME_LEN = 253; // DNS 名称上限
const MAX_PARAM_LEN = 2048;

// ---- 静态 OID（DER 编码）----
const OID_CN = "0603550403";
const OID_ECDSA_SHA256 = "06082a8648ce3d040302";
const OID_BASIC_CONSTRAINTS = "0603551d13";
const OID_KEY_USAGE = "0603551d0f";
const OID_EXT_KEY_USAGE = "0603551d25";
const OID_SERVER_AUTH = "06082b06010505070301";
const OID_SUBJECT_ALT_NAME = "0603551d11";

const hex = (s) => Uint8Array.from(s.match(/../g).map((b) => parseInt(b, 16)));
const enc = new TextEncoder();

function derLen(n) {
  if (n < 0x80) return Uint8Array.of(n);
  const bytes = [];
  while (n > 0) { bytes.unshift(n & 0xff); n >>= 8; }
  return Uint8Array.from([0x80 | bytes.length, ...bytes]);
}

function tlv(tag, ...parts) {
  const body = concat(parts);
  return concat([Uint8Array.of(tag), derLen(body.length), body]);
}

function concat(arrays) {
  const list = arrays.map((a) => (typeof a === "string" ? hex(a) : a));
  const out = new Uint8Array(list.reduce((n, a) => n + a.length, 0));
  let off = 0;
  for (const a of list) { out.set(a, off); off += a.length; }
  return out;
}

const seq = (...p) => tlv(0x30, ...p);
const set = (...p) => tlv(0x31, ...p);
const octet = (b) => tlv(0x04, b);
const utf8 = (s) => tlv(0x0c, enc.encode(s));
const bitstr = (bytes, unused = 0) => tlv(0x03, Uint8Array.of(unused), bytes);
const ctxPrim = (n, b) => tlv(0x80 | n, b);
const ctxCons = (n, ...p) => tlv(0xa0 | n, ...p);

function intBytes(bytes) {
  let b = bytes;
  while (b.length > 1 && b[0] === 0 && (b[1] & 0x80) === 0) b = b.slice(1);
  return tlv(0x02, (b[0] & 0x80) ? concat([Uint8Array.of(0), b]) : b);
}

function pad2(n) { return String(n).padStart(2, "0"); }

function utctime(d) {
  const s = pad2(d.getUTCFullYear() % 100) + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate()) +
    pad2(d.getUTCHours()) + pad2(d.getUTCMinutes()) + pad2(d.getUTCSeconds()) + "Z";
  return tlv(0x17, enc.encode(s));
}

function gtime(d) {
  const s = d.getUTCFullYear() + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate()) +
    pad2(d.getUTCHours()) + pad2(d.getUTCMinutes()) + pad2(d.getUTCSeconds()) + "Z";
  return tlv(0x18, enc.encode(s));
}

function nameCN(value) {
  // Name = SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String } } }
  return seq(set(seq(hex(OID_CN), utf8(value))));
}

// 空 Name（CN 超长时使用，SAN 才是权威）
const emptyName = () => seq();

function extension(oidDer, critical, valueDer) {
  return critical ? seq(hex(oidDer), tlv(0x01, Uint8Array.of(0xff)), octet(valueDer))
                  : seq(hex(oidDer), octet(valueDer));
}

function pem(label, der) {
  let bin = "";
  for (let i = 0; i < der.length; i += 0x8000) {
    bin += String.fromCharCode(...der.subarray(i, i + 0x8000));
  }
  const b64 = btoa(bin);
  const lines = b64.match(/.{1,64}/g).join("\n");
  return `-----BEGIN ${label}-----\n${lines}\n-----END ${label}-----\n`;
}

// WebCrypto 的 ECDSA 签名是 r||s 裸格式，X.509 需要 DER SEQUENCE
function sigRawToDer(raw) {
  const half = raw.length / 2;
  const toInt = (bytes) => {
    let b = bytes;
    while (b.length > 1 && b[0] === 0 && (b[1] & 0x80) === 0) b = b.slice(1);
    return tlv(0x02, (b[0] & 0x80) ? concat([Uint8Array.of(0), b]) : b);
  };
  return seq(toInt(raw.slice(0, half)), toInt(raw.slice(half)));
}

// ==========================================================
// 目标名称校验
// ==========================================================

const fail = (msg) => ({ ok: false, error: msg });

// IPv4：四段十进制，0-255，不允许前导零（避免 010 被当成八进制）
function parseIPv4(s) {
  const parts = s.split(".");
  if (parts.length !== 4) return null;
  const out = new Uint8Array(4);
  for (let i = 0; i < 4; i++) {
    const p = parts[i];
    if (!/^(0|[1-9][0-9]{0,2})$/.test(p)) return null;
    const n = Number(p);
    if (n > 255) return null;
    out[i] = n;
  }
  return out;
}

// IPv6：完整解析，支持 :: 压缩与内嵌 IPv4
function parseIPv6(s) {
  let str = s;
  // 内嵌 IPv4 尾巴（::ffff:1.2.3.4）先转成两组十六进制
  const dotted = str.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
  if (dotted) {
    const v4 = parseIPv4(dotted[1]);
    if (!v4) return null;
    const hi = ((v4[0] << 8) | v4[1]).toString(16);
    const lo = ((v4[2] << 8) | v4[3]).toString(16);
    str = str.slice(0, dotted.index) + hi + ":" + lo;
  }

  const dbl = str.indexOf("::");
  if (dbl !== -1 && str.indexOf("::", dbl + 1) !== -1) return null; // 最多一个 ::

  let head, tail;
  if (dbl === -1) {
    head = str.split(":");
    tail = [];
  } else {
    head = str.slice(0, dbl) === "" ? [] : str.slice(0, dbl).split(":");
    const rest = str.slice(dbl + 2);
    tail = rest === "" ? [] : rest.split(":");
  }

  const isHexGroup = (g) => /^[0-9A-Fa-f]{1,4}$/.test(g);
  if (!head.every(isHexGroup) || !tail.every(isHexGroup)) return null;

  const total = head.length + tail.length;
  let groups;
  if (dbl === -1) {
    if (total !== 8) return null;
    groups = head;
  } else {
    if (total > 7) return null;
    groups = [...head, ...Array(8 - total).fill("0"), ...tail];
  }

  const out = new Uint8Array(16);
  for (let i = 0; i < 8; i++) {
    const v = parseInt(groups[i], 16);
    out[i * 2] = v >> 8;
    out[i * 2 + 1] = v & 0xff;
  }
  return out;
}

// DNS 主机名：小写、≤253 字节、每段 1-63、不以连字符开头结尾、顶级域合法
function validateDNSName(s) {
  if (s.length > MAX_NAME_LEN) return fail("域名过长（上限 253 字节）");
  if (!/^[A-Za-z0-9.-]+$/.test(s)) return fail("域名只能包含字母、数字、连字符和点");
  if (s.startsWith(".") || s.endsWith(".")) return fail("域名不能以点开头或结尾");
  if (s.includes("..")) return fail("域名不能包含连续的点");

  const labels = s.split(".");
  if (labels.length < 2) return fail("域名至少需要两段（如 example.com）");

  for (const label of labels) {
    if (label.length < 1 || label.length > 63) return fail("每段标签长度需为 1-63 字符");
    if (!/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/.test(label)) {
      return fail("标签不能以连字符开头或结尾");
    }
  }

  const tld = labels[labels.length - 1].toLowerCase();
  if (!/^([a-z]{2,63}|xn--[a-z0-9-]{1,59})$/.test(tld)) {
    return fail("顶级域不合法（应为纯字母或 xn-- 开头的 punycode）");
  }
  return { ok: true, type: "dns", name: s.toLowerCase(), san: 0x82 };
}

// 统一入口：返回 { ok, type, name, san, ipBytes }
function validateTarget(raw) {
  if (typeof raw !== "string") return fail("缺少域名参数");
  const s = raw;
  if (s.trim() === "") return fail("域名不能为空");
  if (s.length > MAX_NAME_LEN) return fail("域名过长（上限 253 字节）");

  // 明显不是主机名的输入直接拒绝
  if (/[\/\\?#@\s]/.test(s)) return fail("域名不能包含 / \\ ? # @ 或空白字符");
  if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(s)) return fail("不要带协议前缀（如 https://）");

  if (s.includes(":")) {
    // 单个冒号 + 含点 = 多半是 "域名:端口"，别报成 IPv6 错误
    const colons = s.split(":").length - 1;
    if (colons === 1 && s.includes(".")) {
      return fail("不要带端口号（只填域名或 IP，不含 :端口）");
    }
    const bytes = parseIPv6(s);
    if (!bytes) return fail("IPv6 地址格式不合法");
    return { ok: true, type: "ipv6", name: s.toLowerCase(), san: 0x87, ipBytes: bytes };
  }

  const v4 = parseIPv4(s);
  if (v4) return { ok: true, type: "ipv4", name: s, san: 0x87, ipBytes: v4 };

  // 纯数字和点 = 想写 IPv4 但格式不对，直接说清楚
  if (/^[0-9.]+$/.test(s)) {
    return fail("IPv4 地址格式不合法（四段 0-255，且不能有前导零）");
  }

  return validateDNSName(s);
}

// base64url（可无 padding）→ 字符串
function b64urlDecode(s) {
  let t = s.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  if (t.length % 4 === 1) return null;
  while (t.length % 4 !== 0) t += "=";
  try {
    const bin = atob(t);
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

// d 参数：优先按 base64url 解，解不出来再按明文
function resolveTarget(param) {
  if (param === null || param === undefined) return validateTarget(DEFAULT_CN);
  if (param.length > MAX_PARAM_LEN) return fail("参数过长");

  // 能按 base64url 解出来就只认解码结果，否则错误信息会退化成
  // "对密文本身做校验"的结论，掩盖真正的失败原因。
  // 明文域名/IP 一定含 . 或 :，atob 必失败，因此不会误判。
  const decoded = b64urlDecode(param);
  if (decoded !== null) return validateTarget(decoded);

  return validateTarget(param);
}

// ==========================================================
// 证书生成
// ==========================================================

async function generateCert(target) {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", keys.publicKey));
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));

  const serialBytes = crypto.getRandomValues(new Uint8Array(16));
  serialBytes[0] &= 0x7f;

  const now = new Date();
  const notBefore = now;
  const notAfter = new Date(now.getTime() + VALID_DAYS * 86400000);

  // commonName 在 X.509 里上限 64 字节；超长时省略 CN，只留 SAN（SAN 才是权威）
  const useCN = target.name.length <= 64;
  const name = useCN ? nameCN(target.name) : emptyName();

  const sanValue = target.san === 0x87
    ? tlv(0x87, target.ipBytes)          // iPAddress
    : tlv(0x82, enc.encode(target.name)); // dNSName

  const extensions = seq(
    extension(OID_BASIC_CONSTRAINTS, true, seq()),                        // CA:FALSE
    extension(OID_KEY_USAGE, true, bitstr(Uint8Array.of(0xa0), 5)),       // digitalSignature + keyEncipherment
    extension(OID_EXT_KEY_USAGE, false, seq(hex(OID_SERVER_AUTH))),
    extension(OID_SUBJECT_ALT_NAME, false, seq(sanValue))
  );

  const sigAlg = seq(hex(OID_ECDSA_SHA256));

  const tbs = seq(
    ctxCons(0, Uint8Array.of(0x02, 0x01, 0x02)),   // version v3
    intBytes(serialBytes),
    sigAlg,
    name,                                          // issuer
    seq(utctime(notBefore), gtime(notAfter)),
    name,                                          // subject（自签：与 issuer 相同）
    spki,
    ctxCons(3, extensions)
  );

  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, tbs));
  const cert = seq(tbs, sigAlg, bitstr(sigRawToDer(sig)));

  return {
    certificate_pem: pem("CERTIFICATE", cert),
    private_key_pem: pem("PRIVATE KEY", pkcs8),
    domain: target.name,
    type: target.type,
    subject: useCN ? `CN=${target.name}` : "(CN omitted, see SAN)",
    san: target.san === 0x87 ? `IP:${target.name}` : `DNS:${target.name}`,
    not_before: notBefore.toISOString(),
    not_after: notAfter.toISOString(),
    serial: Array.from(serialBytes, (b) => b.toString(16).padStart(2, "0")).join(""),
  };
}

// ==========================================================
// 路由
// ==========================================================

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", { status: 405, headers: { allow: "GET, HEAD" } });
    }

    if (url.pathname === "/health") {
      return new Response("ok", { headers: { "content-type": "text/plain" } });
    }

    if (url.pathname === "/" || url.pathname === "/generate") {
      const target = resolveTarget(url.searchParams.get("d"));
      if (!target.ok) {
        console.log(JSON.stringify({ event: "cert_rejected", reason: target.error }));
        return json({ error: target.error, code: "invalid_domain" }, 400);
      }

      const cert = await generateCert(target);
      console.log(JSON.stringify({
        event: "cert_issued",
        domain: cert.domain,
        type: cert.type,
        not_after: cert.not_after,
        serial: cert.serial,
      }));
      return json(cert);
    }

    return new Response("not found", { status: 404 });
  },
};
