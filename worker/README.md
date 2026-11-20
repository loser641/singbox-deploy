# ssl.641666.xyz 证书服务（Cloudflare Worker）

为 [sb.sh](../sb.sh) 生成 100 年自签名 TLS 证书。纯 WebCrypto 实现，无依赖、不落盘、不缓存私钥。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/generate` | 默认域名 `www.bing.com`（兼容旧版脚本） |
| GET | `/generate?d=<base64url>` | 为指定域名 / IP 签发 |
| GET | `/health` | 返回 `ok` |

`d` 同时接受 base64url 编码和明文，方便手工测试。能按 base64url 解出来时只认解码结果，
避免错误信息退化成"对密文本身做校验"的结论。

### 响应

成功（200）：

```json
{
  "certificate_pem": "-----BEGIN CERTIFICATE-----\n...",
  "private_key_pem": "-----BEGIN PRIVATE KEY-----\n...",
  "domain": "example.com",
  "type": "dns",
  "subject": "CN=example.com",
  "san": "DNS:example.com",
  "not_before": "2026-11-20T18:19:11.000Z",
  "not_after": "2126-10-27T18:19:11.000Z",
  "serial": "488e55f9716ed757be00cc53074aa601"
}
```

`type` 为 `dns` / `ipv4` / `ipv6`；对应 SAN 类型分别是 `dNSName` / `iPAddress`。

被拒（400）：

```json
{ "error": "域名至少需要两段（如 example.com）", "code": "invalid_domain" }
```

## 校验规则

只接受合法 DNS 主机名与标准 IP 写法，其余一律拒绝：

- 长度 ≤ 253 字节；不能含 `/ \ ? # @`、空白、下划线
- 不能带协议前缀（`https://`）、端口（`:443`）
- 域名：至少两段，每段 1-63 字符，字母数字开头结尾（中间可带连字符），
  顶级域为纯字母或 `xn--` 开头的 punycode
- IPv4：四段十进制、0-255、不允许前导零（`01.2.3.4` 拒绝）
- IPv6：完整解析，支持 `::` 压缩与内嵌 IPv4（`::ffff:1.2.3.4`），最多一个 `::`

CN 超过 64 字节时省略 CN、只写 SAN（SAN 才是客户端校验依据）。

## 部署

```bash
# 通过 API 上传（需要 Workers Scripts:Edit 权限）
# 或使用 wrangler：
wrangler deploy sb-certgen.js --name sb-certgen --compatibility-date 2026-10-13
```

Worker 绑定在 `ssl.641666.xyz`（Workers 自定义域），该域名 DNS 为
`AAAA 100::` + proxied，与 Worker 自定义域配置配合生效。

## 本地测试

```bash
node ../tests/worker-test.mjs ./out
```

覆盖 57 项：DNS / IPv4 / IPv6 正常签发、各类非法输入拒绝、HTTP 方法与路径处理，
并把生成的证书交给 `openssl` 校验签名链与公私钥匹配。
