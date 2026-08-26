# singbox-deploy

sing-box 多协议一键部署脚本，面向低配 VPS（Alpine Linux / Debian / Ubuntu，64MB+ 内存、1GB 存储）。

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

- 自动生成 UUID / REALITY 密钥对 / ShortID
- 需要证书的协议才生成证书、才安装 openssl（不选 TUIC/AnyTLS/Hysteria2 就不装）
- 支持**多选部署**：一次输入 `1,4,6` 可同时添加多个协议
- 节点备注格式：`出口国家简称-协议名`，如 `DE-reality`、`US-reality免流`、`SG-anyreality`，国家简称**自动识别出口 IP 归属地**
- 部署完成后直接列出所有节点分享信息，方便客户端导入
- BBR 自适应开启
- 管理面板：`lsb` 或 `singbox`
- Alpine 使用 **crontab 开机自启**（不依赖 OpenRC）；Debian/Ubuntu 使用 systemd
- 支持添加 / 查看 / 编辑 / 删除配置、查看分享链接、更新、卸载

## 快速开始

在 VPS 上运行：

```bash
wget -O install-singbox.sh https://raw.githubusercontent.com/loser641/singbox-deploy/main/install-singbox.sh
chmod +x install-singbox.sh
./install-singbox.sh
```

或：

```bash
curl -fsSL https://raw.githubusercontent.com/loser641/singbox-deploy/main/install-singbox.sh -o install-singbox.sh && sh install-singbox.sh
```

## 管理面板

安装完成后，输入 `lsb` 或 `singbox` 即可进入管理面板。

## 配置目录

```
/etc/sing-box/
├── config.json              # 合并后的主配置
├── inbounds/                # 每个协议一个配置
├── cert/                    # www.bing.com 自签名证书（用到才生成）
├── links/                   # 客户端分享信息
├── info/                    # 每个协议的元数据（公钥等）
└── server-info              # 节点备注国家简称
```

## 卸载

管理面板中选择卸载（输入 YES 确认），或删除对应 systemd 服务 / crontab 自启项后移除脚本。

## 注意事项

- 需要 sing-box 1.12+（脚本自动安装最新稳定版）
- 端口避免冲突：VLESS 默认 40443、免流 50443、AnyReality 30443，其余随机 20000+
- REALITY 客户端需要填写对应的 `public_key`（脚本会自动保存并在分享信息中输出）
