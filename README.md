# singbox-deploy

sing-box 多协议一键部署脚本，**专为低配 Alpine NAT 小鸡设计**（默认按 64MB 内存 / 1GB 存储 假设编写，不做机器探测），也支持 Debian / Ubuntu。

## 功能

- 自动判断系统架构（amd64 / arm64 / armv7），下载并安装**最新稳定版** sing-box
- 交互式部署以下协议：

  1. VLESS + REALITY（默认端口 40443，SNI itunes.apple.com）
  2. Shadowsocks（AEAD-2022，自动生成密钥）
  3. TUIC
  4. AnyTLS（www.bing.com 100 年自签名证书）
  5. Hysteria2
  6. AnyReality（AnyTLS + REALITY，默认端口 30443，SNI itunes.apple.com，密码自动生成 UUID）
  7. VLESS + REALITY 免流（默认端口 50443，SNI dx-baiducdnct.inter.iqiyi.com）
  8. 全部添加

- 凭据（UUID / 密码 / ShortID）由**内核随机源**生成，REALITY 密钥对自动重试生成——不拉起多余进程，杜绝小内存 OOM 产生空凭据
- **TLS 证书由 Cloudflare Worker（ssl.641666.xyz）在边缘生成**：每次全新密钥对、100 年有效期、CN=www.bing.com，VPS 只需 curl 拉取，**无需安装 openssl**（仅当证书服务不可用时回退本地 openssl 生成）
- 支持**多选部署**：一次输入 `1,4,6` 可同时添加多个协议
- 节点备注格式：`出口国家简称-协议名`，如 `DE-reality`、`US-reality免流`、`SG-anyreality`，国家简称**自动识别出口 IP 归属地**
- 部署完成后直接列出所有节点分享信息 + **TLS 固定证书 PEM**，方便客户端导入
- **自愈能力**：每分钟看门狗 + `local.d` 开机脚本双保险，服务被 OOM 杀死或机器重启后最坏 1 分钟内自动恢复
- BBR 自适应开启（面板内也可一键启用）
- 管理面板：`lsb` 或 `singbox`
- Alpine 使用 **crontab + 看门狗 + local.d**（自动拉起 crond，不依赖 OpenRC）；Debian/Ubuntu 使用 systemd
- 支持添加 / 查看 / 编辑 / 删除配置、修改 DNS、查看分享链接、更新、卸载

## 快速开始

在 VPS 上运行（Alpine/Debian 自带 wget，**无需预装任何下载工具**）：

```bash
sh -c "$(wget -qO- https://github.com/loser641/singbox-deploy/raw/main/sb.sh)"
```

或用 curl：

```bash
sh -c "$(curl -fsSL https://github.com/loser641/singbox-deploy/raw/main/sb.sh)"
```

> **为什么是 `sh -c "$(...)"`，而不是别人家的 `bash <(curl ...)` 或 `curl ... | sh`？**
> - 项目目标机是 Alpine NAT 小鸡，默认只有 busybox ash——**没有 bash**，`<(....)` 进程替换直接报语法错误；
> - `curl ... | sh` 会把脚本内容当标准输入，安装过程中的交互提问会把脚本"吃掉"；
> - `sh -c "$(...)"` 把脚本作为参数执行，stdin 保持终端，ash/bash 通用，下载工具 wget / curl 任一即可。
>
> 旧命令（下载 `install-singbox.sh`）仍然可用，会自动转发到 `sb.sh`。

## 管理面板

安装完成后，输入 `lsb` 或 `singbox` 进入管理面板：

```
1. 添加配置      7. 停止        13. 查看日志
2. 更改配置      8. 重启        14. 更新（手动检查更新，脚本走 GitHub API）
3. 查看配置      9. 服务状态    15. 卸载
4. 删除配置     10. DNS（可修改）16. 退出
5. 分享链接（含 TLS 固定证书 PEM）
6. 启动         11. BBR（可一键启用）
               12. 校验配置
```

面板启动不联网、不拉起多余进程（更新检查只在进入"14. 更新"时才运行）——小内存机器上任何一次进程尖峰都可能触发 OOM，能省则省。

## TLS 证书固定（可选，替代跳过证书验证）

TUIC / AnyTLS / Hysteria2 客户端默认开启 `allow_insecure`。更安全的做法是**固定证书**：

1. 部署完成输出（或面板菜单 5）会直接给出 `-----BEGIN CERTIFICATE-----` 的 PEM；
2. v2rayN：节点设置 → 固定证书 → 粘贴 PEM（或"获取证书"）→ 自动禁用跳过证书验证；
3. SNI 保持 `www.bing.com` 不变（伪装不受影响），同机器所有节点共用同一张证书。

注意：证书每次安装随机生成（避免共享私钥），**重装后需重新固定**。

## 配置目录

```
/etc/sing-box/
├── config.json              # 合并后的主配置（先校验通过才替换，坏配置不上盘）
├── inbounds/                # 每个协议一个配置
├── cert/                    # www.bing.com 证书（Worker 生成，无需 openssl）
├── links/                   # 客户端分享信息
├── info/                    # 每个协议的元数据（公钥等）
├── dns.json                 # DNS 配置（面板 10 修改，sing-box 1.14 新格式）
└── server-info              # 节点备注国家简称
```

## 卸载

管理面板中选择卸载（输入 YES 确认），或删除对应 systemd 服务 / crontab 自启项后移除脚本。

## NAT 小鸡注意事项

- **端口映射要在服务商面板手动开启**，且注意两点：
  - TUIC / Hysteria2 是 **UDP** 协议——TCP 映射不带 UDP，需单独开 UDP 映射；
  - 尽量开**同端口映射**（外部端口 = 内部端口），分享链接里的端口才会与实际可达端口一致；
- 验证方法：TCP 用 `nc -zv IP 端口`，UDP 可发 QUIC 探测看是否有 Version Negotiation 回包；
- 内存按 **64MB** 设计：安装/下载全程限速（`--limit-rate=2m`）压住解压脏页尖峰，sing-box 运行带 `GOMEMLIMIT=48MiB` 限制 Go 堆；
- 服务可靠性：进程被杀一分钟内看门狗自动拉起；若手动管理，记得保持 crond 运行（脚本会自动拉起）。

## 协议选择建议（NAT 机）

| 场景 | 建议 |
|---|---|
| 只开了 TCP 映射 | VLESS-REALITY / AnyTLS / Shadowsocks |
| UDP 映射可用 | TUIC / Hysteria2（QUIC，低延迟） |
| 想要证书校验又保持伪装 | TLS 固定证书（见上文） |

- 需要 sing-box 1.12+（脚本自动安装最新稳定版；DNS 使用 1.14 新格式）
- 端口避免冲突：VLESS 默认 40443、免流 50443、AnyReality 30443，其余随机 20000+
- REALITY 客户端需要填写对应的 `public_key`（脚本会自动保存并在分享信息中输出）
