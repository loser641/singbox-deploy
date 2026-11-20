// 本地测试：直接跑 Worker 的 fetch 入口，验证校验逻辑与证书可用性
import worker from "../worker/sb-certgen.js";
import { writeFileSync, mkdirSync } from "node:fs";

const OUT = process.argv[2] || "./out";
mkdirSync(OUT, { recursive: true });

let pass = 0, fail = 0;
function check(name, cond, extra = "") {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name} ${extra}`); }
}

const b64url = (s) => Buffer.from(s, "utf8").toString("base64url");
const call = (query = "") => worker.fetch(new Request("https://ssl.641666.xyz/generate" + query));

console.log("=== 应通过 ===");
const good = [
  "example.com",
  "www.bing.com",
  "a.b.c.d.example.co.uk",
  "xn--fiqs8s.xn--fiqz9s",   // 中文 punycode
  "my-host.example.com",
  "a1.example.com",
  "1.2.3.4",
  "255.255.255.255",
  "0.0.0.0",
  "::1",
  "2001:db8::1",
  "2001:0db8:0000:0000:0000:0000:0000:0001",
  "fe80::1",
  "::ffff:192.168.1.1",
  "2001:db8:0:0:1:0:0:1",
  "Example.COM",             // 大写应被归一化
];
for (const d of good) {
  const r = await call("?d=" + b64url(d));
  const body = await r.json();
  check(`b64 ${d} → 200`, r.status === 200, `status=${r.status} ${JSON.stringify(body).slice(0, 120)}`);
}

console.log("\n=== 明文参数也应可用 ===");
{
  const r = await call("?d=" + encodeURIComponent("example.org"));
  const body = await r.json();
  check("plain example.org → 200", r.status === 200, `status=${r.status}`);
  check("domain 回显", body.domain === "example.org", JSON.stringify(body.domain));
}

console.log("\n=== 默认值 ===");
{
  const r = await call("");
  const body = await r.json();
  check("无参数 → 200", r.status === 200);
  check("默认 www.bing.com", body.domain === "www.bing.com", body.domain);
  check("默认 type=dns", body.type === "dns", body.type);
}

console.log("\n=== 应拒绝 ===");
const bad = [
  "localhost",
  "example",
  ".example.com",
  "example.com.",
  "exa..mple.com",
  "-example.com",
  "example-.com",
  "exam ple.com",
  "https://example.com",
  "ftp://example.com",
  "example.com/path",
  "example.com?x=1",
  "user@example.com",
  "exam_ple.com",
  "example.123",
  "example.c",
  "256.1.1.1",
  "1.2.3",
  "01.2.3.4",           // 前导零
  "1.2.3.4.5",
  "::1::2",
  "2001:db8:::1",
  "gggg::1",
  "2001:db8::1::2",
  "1:2:3:4:5:6:7:8:9",
  "",
  "   ",
  "example.com\n",
  "a".repeat(64) + ".com",
  "a".repeat(250) + ".com",
  "<script>.com",
  "example.com:443",
  "中文.com",
];
for (const d of bad) {
  const r = await call("?d=" + b64url(d));
  let body = {};
  try { body = await r.json(); } catch {}
  check(`拒绝 ${JSON.stringify(d).slice(0, 40)} → 400`, r.status === 400, `status=${r.status}`);
}

console.log("\n=== 方法限制 ===");
{
  const r = await worker.fetch(new Request("https://ssl.641666.xyz/generate", { method: "POST" }));
  check("POST → 405", r.status === 405, String(r.status));
  const h = await worker.fetch(new Request("https://ssl.641666.xyz/health"));
  check("/health → ok", (await h.text()) === "ok");
  const n = await worker.fetch(new Request("https://ssl.641666.xyz/nope"));
  check("/nope → 404", n.status === 404);
}

console.log("\n=== 导出证书并用 openssl 校验 ===");
const cases = [
  ["example.com", "dns"],
  ["10.20.30.40", "ipv4"],
  ["2001:db8::abcd", "ipv6"],
];
for (const [d, kind] of cases) {
  const r = await call("?d=" + b64url(d));
  const body = await r.json();
  const base = `${OUT}/${kind}`;
  writeFileSync(`${base}.crt`, body.certificate_pem);
  writeFileSync(`${base}.key`, body.private_key_pem);
  console.log(`  写入 ${base}.crt / .key  (${body.san})`);
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
