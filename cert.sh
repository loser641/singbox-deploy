#!/bin/sh
# ==========================================================
# sing-box 真实证书申请工具（acme.sh）
#
# 独立于主脚本：只在运行时下载 acme.sh，不预装。
# 申请到的真实证书装入 /etc/sing-box/cert/www.bing.com.crt/.key
# （文件名固定）：主脚本部署协议时看到已有证书会直接复用，
# 不会用自签名覆盖。
# acme.sh 安装后自带定时续期，续期后自动重启 sing-box。
#
# 用法：
#   交互：sh cert.sh
#   参数：sh cert.sh -d 域名 -m dns_cf|standalone|webroot
#              [-w 网站目录] [-e 邮箱] [--staging] [-y]
# ==========================================================

BASE="/etc/sing-box"
CERT_DIR="$BASE/cert"
CRT="$CERT_DIR/www.bing.com.crt"
KEY="$CERT_DIR/www.bing.com.key"
ACME="$HOME/.acme.sh/acme.sh"

DOMAIN=""
METHOD=""
WEBROOT=""
EMAIL=""
STAGING=""
YES=""

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)  DOMAIN="$2"; shift 2 ;;
        -m|--method)  METHOD="$2"; shift 2 ;;
        -w|--webroot) WEBROOT="$2"; shift 2 ;;
        -e|--email)   EMAIL="$2"; shift 2 ;;
        --staging)    STAGING=1; shift ;;
        -y|--yes)     YES=1; shift ;;
        -h|--help)
            echo "用法：sh cert.sh -d 域名 -m dns_cf|standalone|webroot [-w 网站目录] [-e 邮箱] [--staging] [-y]"
            exit 0 ;;
        *)
            echo "未知参数：$1（--help 看用法）"
            exit 1 ;;
    esac
done

command_exists() { command -v "$1" >/dev/null 2>&1; }

show_cert_status() {
    echo "当前证书状态："
    if [ -s "$CRT" ] && [ -s "$KEY" ]; then
        if command_exists openssl; then
            openssl x509 -in "$CRT" -noout -issuer -subject -dates 2>/dev/null || echo "  已存在但无法解析：$CRT"
        else
            echo "  已存在：$CRT"
        fi
    else
        echo "  （无）"
    fi
}

echo "=========================================="
echo " sing-box 真实证书申请（acme.sh）"
echo "=========================================="
show_cert_status
echo

if [ -z "$METHOD" ]; then
    echo "验证方式："
    echo "1. DNS 验证（Cloudflare）—— NAT 小鸡 / 80 端口不通适用"
    echo "2. HTTP 验证（standalone）—— 需要 80 端口公网可达"
    echo "3. HTTP 验证（webroot）—— 已有网站目录"
    echo "0. 退出"
    printf "请选择："
    read ANS
    case "$ANS" in
        1) METHOD="dns_cf" ;;
        2) METHOD="standalone" ;;
        3) METHOD="webroot" ;;
        *) echo "已取消。"; exit 0 ;;
    esac
fi

case "$METHOD" in
    dns_cf|standalone|webroot) ;;
    *) echo "不支持的验证方式：$METHOD（可用 dns_cf/standalone/webroot）"; exit 1 ;;
esac

if [ -z "$DOMAIN" ]; then
    printf "请输入域名（如 ns.example.com）："
    read DOMAIN
fi
[ -n "$DOMAIN" ] || { echo "域名不能为空。"; exit 1; }

if [ -z "$EMAIL" ] && [ -z "$YES" ]; then
    printf "请输入邮箱（到期提醒，留空默认 admin@%s）：" "$DOMAIN"
    read EMAIL
fi
[ -n "$EMAIL" ] || EMAIL="admin@$DOMAIN"

if [ -z "$STAGING" ] && [ -z "$YES" ]; then
    echo
    echo "证书类型："
    echo "1. 正式（Let's Encrypt）"
    echo "2. 测试（staging，不限速率，先跑通流程）"
    printf "请选择（默认 1）："
    read ANS
    [ "$ANS" = "2" ] && STAGING=1
fi

if [ "$METHOD" = "webroot" ]; then
    if [ -z "$WEBROOT" ]; then
        printf "请输入网站根目录（如 /var/www/html）："
        read WEBROOT
    fi
    [ -d "$WEBROOT" ] || { echo "目录不存在：$WEBROOT"; exit 1; }
fi

if [ "$METHOD" = "dns_cf" ]; then
    if [ -z "$CF_Token" ]; then
        printf "Cloudflare API Token（需 Zone.DNS Edit 权限）："
        read CF_Token
    fi
    if [ -z "$CF_Account_ID" ]; then
        printf "Cloudflare Account ID："
        read CF_Account_ID
    fi
    export CF_Token CF_Account_ID
    [ -n "$CF_Token" ] || { echo "缺少 CF Token。"; exit 1; }
fi

if [ -s "$CRT" ] && [ -s "$KEY" ] && [ -z "$YES" ]; then
    echo
    printf "已有证书将被新证书覆盖，继续？[y/N]："
    read ANS
    case "$ANS" in
        y|Y|yes|YES) ;;
        *) echo "已取消。"; exit 0 ;;
    esac
fi

# ---------- 1. 依赖（选了才装） ----------

echo
echo "[1/4] 检查依赖..."

MISSING=""
for p in bash openssl curl; do
    command_exists "$p" || MISSING="$MISSING $p"
done
if [ "$METHOD" = "standalone" ]; then
    command_exists socat || MISSING="$MISSING socat"
fi

if [ -n "$MISSING" ]; then
    echo "安装依赖：$MISSING"
    if [ -f /etc/alpine-release ]; then
        apk add $MISSING >/dev/null 2>&1 || { echo "依赖安装失败：$MISSING"; exit 1; }
    elif command_exists apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING >/dev/null 2>&1 || { echo "依赖安装失败：$MISSING"; exit 1; }
    else
        echo "不支持的系统，请手动安装：$MISSING"
        exit 1
    fi
fi

# ---------- 2. acme.sh（选了才下载） ----------

echo "[2/4] 准备 acme.sh..."

if [ -x "$ACME" ]; then
    echo "已存在 acme.sh，跳过下载。"
else
    curl -fsSL --max-time 60 https://get.acme.sh -o /tmp/get-acme.sh || { echo "acme.sh 下载失败。"; exit 1; }
    sh /tmp/get-acme.sh email="$EMAIL" >/dev/null 2>&1
    rm -f /tmp/get-acme.sh
    [ -x "$ACME" ] || { echo "acme.sh 安装失败。"; exit 1; }
    echo "acme.sh 已安装到 $HOME/.acme.sh"
fi

# ---------- 3. 申请证书 ----------

echo "[3/4] 申请证书（$METHOD / $DOMAIN）..."

if [ -n "$STAGING" ]; then
    CA_OPT="--staging"
else
    CA_OPT="--server letsencrypt"
fi

case "$METHOD" in
    dns_cf)
        "$ACME" --issue -d "$DOMAIN" --dns dns_cf $CA_OPT
        ;;
    standalone)
        "$ACME" --issue -d "$DOMAIN" --standalone $CA_OPT
        ;;
    webroot)
        "$ACME" --issue -d "$DOMAIN" -w "$WEBROOT" $CA_OPT
        ;;
esac

# ---------- 4. 安装到 /etc/sing-box/cert ----------

echo "[4/4] 安装证书到 $CERT_DIR ..."

mkdir -p "$CERT_DIR"

if command_exists systemctl; then
    RELOAD="systemctl restart sing-box"
else
    RELOAD="pkill -f sing-box.run 2>/dev/null; sleep 1; GOMEMLIMIT=24MiB /usr/local/bin/sing-box run -c $BASE/config.json >/dev/null 2>&1 & sleep 2; echo 800 > /proc/\$(pgrep -f sing-box.run | head -1)/oom_score_adj 2>/dev/null; true"
fi

"$ACME" --install-cert -d "$DOMAIN" --fullchain-file "$CRT" --key-file "$KEY" --reloadcmd "$RELOAD" || {
    echo "证书安装失败。"
    exit 1
}

chmod 600 "$KEY" 2>/dev/null
chmod 644 "$CRT" 2>/dev/null

echo
echo "=========================================="
echo " 真实证书已安装"
echo "=========================================="
command_exists openssl && openssl x509 -in "$CRT" -noout -issuer -subject -dates 2>/dev/null
echo
echo "证书：$CRT"
echo "私钥：$KEY"
echo
echo "客户端使用："
echo "  · SNI / 服务器名填写：$DOMAIN"
echo "  · 证书按系统根证书校验即可（v2rayN 关闭 allow_insecure），无需固定证书"
echo "  · REALITY 类节点不使用此证书，不受影响"
echo
echo "自动续期：acme.sh 已配置定时任务，续期后自动重启 sing-box。"

if [ -n "$STAGING" ]; then
    echo
    echo "[!] 当前为 staging 测试证书，客户端不可用系统根校验。"
    echo "    流程验证通过后，去掉 --staging 重新申请正式证书。"
fi
