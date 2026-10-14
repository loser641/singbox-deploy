#!/bin/sh
# 兼容入口：真实安装脚本是 sb.sh，本文件仅为旧命令保留，参数原样透传。
_s="$(wget -qO- https://raw.githubusercontent.com/loser641/singbox-deploy/main/sb.sh 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/loser641/singbox-deploy/main/sb.sh)"
[ -n "$_s" ] || { echo "下载 sb.sh 失败，请检查网络。" >&2; exit 1; }
exec sh -c "$_s" sb "$@"
