#!/bin/sh

# ==========================================================
# sing-box Multi-Protocol Server Installer
#
# Supported:
#   Alpine Linux
#   Debian
#   Ubuntu
#
# Protocol:
#   VLESS + REALITY
#   VLESS + REALITY 免流
#   TUIC
#   AnyTLS
#   AnyReality (AnyTLS + REALITY)
#   Shadowsocks
#   Hysteria2
#
# Features:
#   - Auto detect architecture
#   - Latest stable sing-box
#   - UUID / Reality KeyPair / ShortID
#   - 100-year self-signed www.bing.com certificate
#   - BBR auto enable
#   - Custom DNS
#   - Interactive configuration
#   - Multi-config management
#   - VLESS / TUIC / SS / Hysteria2 / AnyTLS links
#   - systemd / crontab（Alpine）
#   - lsb management panel
# ==========================================================

set -u

SCRIPT_VERSION="2026.10.14.2"

BIN="/usr/local/bin/sing-box"
BASE="/etc/sing-box"
INBOUND_DIR="$BASE/inbounds"
LINK_DIR="$BASE/links"
CERT_DIR="$BASE/cert"
CONFIG="$BASE/config.json"
INFO="$BASE/server-info"
COUNTRY="US"

mkdir -p "$BASE"

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行。"
    exit 1
fi

# 限制 Go 堆内存，避免小内存机器上 sing-box 启动/运行时触发 OOM
export GOMEMLIMIT=24MiB

# ==========================================================
# Common
# ==========================================================

random_port() {
    awk 'BEGIN{srand(); print int(20000+rand()*40000)}'
}

random_password() {
    # 用内核随机源，避免拉起 sing-box 进程（小内存机器上会被 OOM 杀掉导致空值）
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
    else
        "$BIN" generate rand --base64 24 2>/dev/null | tr -d '\n'
    fi
}

pause() {
    echo
    printf "按 Enter 继续..."
    read x
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ask_yes_no() {

    printf "%s [y/N]: " "$1"
    read ANSWER

    case "$ANSWER" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

work_dir() {
    # /tmp 在小内存机器上是 tmpfs（内存盘），大文件放进去会触发 OOM 杀掉 SSH 会话
    for d in /var/tmp /root /usr/local/src; do
        mkdir -p "$d" 2>/dev/null || continue
        case "$(df -P "$d" 2>/dev/null | tail -n 1 | awk '{print $1}')" in
            tmpfs*) ;;
            *)
                echo "$d/$1"
                return 0
                ;;
        esac
    done

    echo "/root/$1"
}

rate_opt() {
    # 项目默认目标是 64MB 小内存 Alpine NAT 机，不做机器探测（NAT 机内存
    # 读数不准）。限速压住解压脏页的生成速率，避免触发 OOM
    echo "--limit-rate=2m"
}

# ==========================================================
# Detect OS
# ==========================================================

detect_os() {

    if [ ! -f /etc/os-release ]; then
        echo "无法识别 Linux 系统。"
        exit 1
    fi

    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64)
            SB_ARCH="amd64"
            ;;
        aarch64|arm64)
            SB_ARCH="arm64"
            ;;
        armv7l|armv7)
            SB_ARCH="armv7"
            ;;
        *)
            echo "不支持架构：$ARCH"
            exit 1
            ;;
    esac

    case "$OS_ID" in
        alpine)
            LIBC="musl"
            ;;
        debian|ubuntu)
            LIBC="glibc"
            ;;
        *)
            echo "当前仅支持 Alpine / Debian / Ubuntu。"
            echo "当前系统：$OS_NAME"
            exit 1
            ;;
    esac

    echo
    echo "系统      : $OS_NAME"
    echo "架构      : $ARCH"
    echo "sing-box  : linux-$SB_ARCH"
    echo "C Library : $LIBC"
}

# ==========================================================
# Dependencies
# ==========================================================

install_dependencies() {

    echo
    echo "[+] 安装依赖..."

    if [ "$OS_ID" = "alpine" ]; then

        apk update >/dev/null 2>&1

        apk add \
            curl \
            wget \
            tar \
            gzip \
            ca-certificates \
            iproute2 \
            jq \
            procps \
            coreutils \
            openssl \
            >/dev/null 2>&1

    else

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            curl \
            wget \
            tar \
            gzip \
            ca-certificates \
            iproute2 \
            jq \
            procps \
            coreutils \
            openssl \
            >/dev/null 2>&1
    fi
}

# ==========================================================
# Latest Stable sing-box
# ==========================================================

install_singbox() {

    echo
    echo "=========================================="
    echo " 下载最新稳定版 sing-box"
    echo "=========================================="

    API="https://api.github.com/repos/SagerNet/sing-box/releases"

    JSON="$(curl -fsSL "$API?per_page=20" 2>/dev/null || true)"

    VERSION=""

    if [ -n "$JSON" ]; then

        VERSION="$(
            printf '%s\n' "$JSON" |
            jq -r '
                .[]
                | select(.prerelease == false)
                | .tag_name
            ' |
            head -n 1
        )"

        VERSION="${VERSION#v}"
    fi

    if [ -z "$VERSION" ]; then
        echo "无法获取 GitHub 最新版本。"
        echo "请检查网络。"
        exit 1
    fi

    echo "最新稳定版：$VERSION"

    case "$SB_ARCH-$LIBC" in

        amd64-musl)
            FILE="sing-box-${VERSION}-linux-amd64-musl.tar.gz"
            ;;

        arm64-musl)
            FILE="sing-box-${VERSION}-linux-arm64-musl.tar.gz"
            ;;

        armv7-musl)
            FILE="sing-box-${VERSION}-linux-armv7.tar.gz"
            ;;

        amd64-glibc)
            FILE="sing-box-${VERSION}-linux-amd64.tar.gz"
            ;;

        arm64-glibc)
            FILE="sing-box-${VERSION}-linux-arm64.tar.gz"
            ;;

        armv7-glibc)
            FILE="sing-box-${VERSION}-linux-armv7.tar.gz"
            ;;

        *)
            echo "没有匹配的安装包。"
            exit 1
            ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${FILE}"

    TMP="$(work_dir singbox-install)"

    echo "[+] $URL"

    OK=""
    TRY=0

    while [ -z "$OK" ] && [ "$TRY" -lt 3 ]; do
        TRY=$((TRY+1))

        rm -rf "$TMP"
        mkdir -p "$TMP"

        if wget -q --show-progress $(rate_opt) "$URL" -O- | tar -xzf - -C "$TMP"; then
            OK=1
        else
            echo "下载或解压失败，重试 $TRY/3 ..."
            sleep 3
        fi
    done

    [ -n "$OK" ] || {
        echo "下载或解压失败。"
        rm -rf "$TMP"
        exit 1
    }

    SB="$(find "$TMP" -type f -name sing-box | head -n 1)"

    [ -n "$SB" ] || {
        echo "sing-box 二进制不存在。"
        exit 1
    }

    mv "$SB" "$BIN"
    chown 0:0 "$BIN" 2>/dev/null || true
    chmod 755 "$BIN"

    rm -rf "$TMP"

    printf '%s\n' "$VERSION" > "$BASE/sing-box-version"

    echo
    "$BIN" version
}

# ==========================================================
# Generate 100-year www.bing.com certificate
# ==========================================================

generate_certificate() {

    mkdir -p "$CERT_DIR"

    CRT="$CERT_DIR/www.bing.com.crt"
    KEY="$CERT_DIR/www.bing.com.key"

    if [ -s "$CRT" ] && [ -s "$KEY" ]; then
        echo "[+] 已存在 www.bing.com 证书（含 acme 真证书），直接复用。"
        return
    fi

    # 残缺证书（空文件或缺一半）清掉重新生成，避免新旧混用
    rm -f "$CRT" "$KEY"

    echo
    echo "=========================================="
    echo " 生成 100 年自签名 TLS 证书"
    echo "=========================================="

    # 优先使用证书服务（Cloudflare Worker 生成，无需安装 openssl）
    CERT_SERVICE="https://ssl.641666.xyz/generate"

    CERT_JSON="$(curl -fsSL --max-time 30 "$CERT_SERVICE" 2>/dev/null || true)"

    if [ -n "$CERT_JSON" ]; then
        printf '%s' "$CERT_JSON" | jq -r '.certificate_pem // empty' > "$CRT" 2>/dev/null
        printf '%s' "$CERT_JSON" | jq -r '.private_key_pem // empty' > "$KEY" 2>/dev/null
    fi

    if [ ! -s "$KEY" ] || [ ! -s "$CRT" ]; then

        echo "[+] 证书服务不可用，回退 openssl 本地生成。"

        command_exists openssl || {
            if [ "$OS_ID" = "alpine" ]; then
                apk add openssl >/dev/null 2>&1
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y openssl >/dev/null 2>&1
            fi
        }

        command_exists openssl || {
            echo "证书服务不可用且 openssl 安装失败。"
            return 1
        }

        cat > "$CERT_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = Washington
L = Redmond
O = Microsoft
OU = Web
CN = www.bing.com

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = www.bing.com
EOF

        openssl req \
            -x509 \
            -nodes \
            -newkey rsa:2048 \
            -sha256 \
            -days 36500 \
            -keyout "$KEY" \
            -out "$CRT" \
            -config "$CERT_DIR/openssl.cnf" \
            >/dev/null 2>&1
    fi

    if [ ! -s "$KEY" ] || [ ! -s "$CRT" ]; then
        echo "证书生成失败。"
        return 1
    fi

    chmod 600 "$KEY"
    chmod 644 "$CRT"

    echo
    echo "证书：$CRT"
    echo "私钥：$KEY"

    openssl x509 \
        -in "$CRT" \
        -noout \
        -subject \
        -issuer \
        -dates 2>/dev/null || echo "(证书已生成，如需查看详情请安装 openssl)"
}

# ==========================================================
# Ensure certificate (only needed by TUIC / AnyTLS / Hysteria2)
# ==========================================================

ensure_certificate() {

    if [ -s "$CERT_DIR/www.bing.com.crt" ] && [ -s "$CERT_DIR/www.bing.com.key" ]; then
        return
    fi

    generate_certificate
}

# ==========================================================
# BBR
# ==========================================================

enable_bbr() {

    echo
    echo "=========================================="
    echo " BBR 检测"
    echo "=========================================="

    if [ ! -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
        echo "当前系统无法检测 BBR。"
        return
    fi

    AVAILABLE="$(
        cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
    )"

    CURRENT="$(
        cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
    )"

    echo "当前：$CURRENT"
    echo "可用：$AVAILABLE"

    case " $AVAILABLE " in
        *" bbr "*)

            echo "[+] 检测到 BBR，启用。"

            mkdir -p /etc/sysctl.d

            cat > /etc/sysctl.d/99-sing-box-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

            sysctl --system >/dev/null 2>&1 || true

            if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
                sysctl -w \
                    net.ipv4.tcp_congestion_control=bbr \
                    >/dev/null 2>&1 || true
            fi

            ;;

        *)
            echo "当前内核不支持 BBR，不修改。"
            ;;
    esac
}

# ==========================================================
# DNS
# ==========================================================

configure_dns() {

    echo
    echo "=========================================="
    echo " DNS 设置"
    echo "=========================================="

    echo "默认：1.1.1.1"
    echo
    printf "请输入 DNS，可用逗号分隔 [1.1.1.1]: "
    read DNS_INPUT

    [ -n "$DNS_INPUT" ] || DNS_INPUT="1.1.1.1"

    DNS1="$(printf '%s' "$DNS_INPUT" | cut -d',' -f1)"
    DNS2="$(printf '%s' "$DNS_INPUT" | awk -F',' 'NF > 1 { print $2 }')"

    if [ -n "$DNS2" ]; then

        cat > "$BASE/dns.json" <<EOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-1",
        "server": "$DNS1"
      },
      {
        "type": "udp",
        "tag": "dns-2",
        "server": "$DNS2"
      }
    ],
    "final": "dns-1"
  }
}
EOF

    else

        cat > "$BASE/dns.json" <<EOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-1",
        "server": "$DNS1"
      }
    ],
    "final": "dns-1"
  }
}
EOF

    fi

    echo "DNS：$DNS_INPUT"
}

# ==========================================================
# UUID / Password / Reality
# ==========================================================

generate_uuid() {
    # 用内核随机源，避免拉起 sing-box 进程（小内存机器上会被 OOM 杀掉导致空值）
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        "$BIN" generate uuid 2>/dev/null
    fi
}

generate_reality() {

    # sing-box 进程在小内存机器上可能被 OOM 杀掉导致空输出，重试兜底
    REALITY=""
    TRY=0

    while [ -z "$REALITY" ] && [ "$TRY" -lt 3 ]; do
        TRY=$((TRY+1))
        REALITY="$("$BIN" generate reality-keypair 2>/dev/null)"
        [ -n "$REALITY" ] || sleep 1
    done

    PRIVATE_KEY="$(
        printf '%s\n' "$REALITY" |
        sed -n 's/^PrivateKey: //p'
    )"

    PUBLIC_KEY="$(
        printf '%s\n' "$REALITY" |
        sed -n 's/^PublicKey: //p'
    )"

    if [ -r /dev/urandom ]; then
        SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    else
        SHORT_ID="$("$BIN" generate rand 8 --hex 2>/dev/null)"
    fi

    [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || {
        echo "Reality 密钥生成失败。"
        return 1
    }
}

# ==========================================================
# Common TLS
# ==========================================================

write_standard_tls() {

    cat <<EOF
"tls": {
  "enabled": true,
  "server_name": "www.bing.com",
  "min_version": "1.2",
  "certificate_path": "$CERT_DIR/www.bing.com.crt",
  "key_path": "$CERT_DIR/www.bing.com.key"
}
EOF
}

# ==========================================================
# VLESS REALITY
# ==========================================================

add_vless_reality() {

    TAG="vless-reality"
    FILE="$INBOUND_DIR/${TAG}.json"

    if [ -f "$FILE" ]; then
        echo "该配置已经存在。"
        return
    fi

    UUID="$(generate_uuid)"; [ -n "$UUID" ] || { echo "UUID 生成失败。"; return 1; }
    generate_reality || return 1

    SNI="itunes.apple.com"
    PORT=40443

    echo
    printf "VLESS REALITY 端口 [40443]: "
    read X

    [ -n "$X" ] && PORT="$X"

    printf "SNI [itunes.apple.com]: "
    read X

    [ -n "$X" ] && SNI="$X"

    cat > "$FILE" <<EOF
{
  "type": "vless",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,
  "users": [
    {
      "name": "user1",
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "min_version": "1.3",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$SNI",
        "server_port": 443
      },
      "private_key": "$PRIVATE_KEY",
      "short_id": [
        "$SHORT_ID"
      ]
    }
  }
}
EOF

    save_info "$TAG" \
        "UUID=$UUID" \
        "PUBLIC_KEY=$PUBLIC_KEY" \
        "SHORT_ID=$SHORT_ID" \
        "SNI=$SNI" \
        "PORT=$PORT"

    append_order "$(basename "$FILE")"

    echo "VLESS REALITY 已添加。"
}

# ==========================================================
# VLESS REALITY 免流
# ==========================================================

add_vless_reality_free() {

    TAG="vless-reality-免流"
    FILE="$INBOUND_DIR/vless-reality-free.json"

    if [ -f "$FILE" ]; then
        echo "该配置已经存在。"
        return
    fi

    UUID="$(generate_uuid)"; [ -n "$UUID" ] || { echo "UUID 生成失败。"; return 1; }
    generate_reality || return 1

    SNI="dx-baiducdnct.inter.iqiyi.com"
    PORT=50443

    echo
    printf "VLESS REALITY 免流 端口 [50443]: "
    read X

    [ -n "$X" ] && PORT="$X"

    printf "SNI [$SNI]: "
    read X

    [ -n "$X" ] && SNI="$X"

    cat > "$FILE" <<EOF
{
  "type": "vless",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,
  "users": [
    {
      "name": "user1",
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "min_version": "1.3",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$SNI",
        "server_port": 443
      },
      "private_key": "$PRIVATE_KEY",
      "short_id": [
        "$SHORT_ID"
      ]
    }
  }
}
EOF

    save_info "$TAG" \
        "UUID=$UUID" \
        "PUBLIC_KEY=$PUBLIC_KEY" \
        "SHORT_ID=$SHORT_ID" \
        "SNI=$SNI" \
        "PORT=$PORT"

    append_order "$(basename "$FILE")"

    echo "VLESS REALITY 免流已添加。"
}

# ==========================================================
# TUIC
# ==========================================================

add_tuic() {

    TAG="tuic"
    FILE="$INBOUND_DIR/${TAG}.json"

    ensure_certificate || return 1

    UUID="$(generate_uuid)"; [ -n "$UUID" ] || { echo "UUID 生成失败。"; return 1; }
    PASSWORD="$(random_password)"; [ -n "$PASSWORD" ] || { echo "密码生成失败。"; return 1; }
    PORT="$(random_port)"

    echo
    printf "TUIC 端口 [$PORT]: "
    read X

    [ -n "$X" ] && PORT="$X"

    cat > "$FILE" <<EOF
{
  "type": "tuic",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,
  "users": [
    {
      "name": "user1",
      "uuid": "$UUID",
      "password": "$PASSWORD"
    }
  ],
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "alpn": [
      "h3"
    ],
    "min_version": "1.2",
    "certificate_path": "$CERT_DIR/www.bing.com.crt",
    "key_path": "$CERT_DIR/www.bing.com.key"
  }
}
EOF

    save_info "$TAG" \
        "UUID=$UUID" \
        "PASSWORD=$PASSWORD" \
        "PORT=$PORT"

    append_order "$(basename "$FILE")"

    echo "TUIC 已添加。"
}

# ==========================================================
# AnyTLS
# ==========================================================

add_anytls() {

    TAG="anytls"
    FILE="$INBOUND_DIR/${TAG}.json"

    ensure_certificate || return 1

    PASSWORD="$(random_password)"; [ -n "$PASSWORD" ] || { echo "密码生成失败。"; return 1; }
    PORT="$(random_port)"

    echo
    printf "AnyTLS 端口 [$PORT]: "
    read X

    [ -n "$X" ] && PORT="$X"

    cat > "$FILE" <<EOF
{
  "type": "anytls",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,
  "users": [
    {
      "name": "user1",
      "password": "$PASSWORD"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "min_version": "1.2",
    "certificate_path": "$CERT_DIR/www.bing.com.crt",
    "key_path": "$CERT_DIR/www.bing.com.key"
  }
}
EOF

    save_info "$TAG" \
        "PASSWORD=$PASSWORD" \
        "PORT=$PORT"

    append_order "$(basename "$FILE")"

    echo "AnyTLS 已添加。"
}

# ==========================================================
# Shadowsocks
# ==========================================================

add_shadowsocks() {

    TAG="shadowsocks"
    FILE="$INBOUND_DIR/${TAG}.json"

    PORT="$(random_port)"

    echo
    echo "Shadowsocks 加密方式："
    echo
    echo "1. 2022-blake3-aes-128-gcm"
    echo "2. 2022-blake3-aes-256-gcm"
    echo "3. 2022-blake3-chacha20-poly1305"
    echo

    printf "选择 [1-3]，默认 1："
    read M

    case "$M" in
        2)
            METHOD="2022-blake3-aes-256-gcm"
            KEYLEN=32
            ;;
        3)
            METHOD="2022-blake3-chacha20-poly1305"
            KEYLEN=32
            ;;
        *)
            METHOD="2022-blake3-aes-128-gcm"
            KEYLEN=16
            ;;
    esac

    PASSWORD="$("$BIN" generate rand --base64 "$KEYLEN")"

    echo
    printf "Shadowsocks 端口 [$PORT]: "
    read X

    [ -n "$X" ] && PORT="$X"

    cat > "$FILE" <<EOF
{
  "type": "shadowsocks",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,
  "network": "tcp",
  "method": "$METHOD",
  "password": "$PASSWORD",
  "multiplex": {
    "enabled": true
  }
}
EOF

    save_info "$TAG" \
        "METHOD=$METHOD" \
        "PASSWORD=$PASSWORD" \
        "PORT=$PORT"

    append_order "$(basename "$FILE")"

    echo "Shadowsocks 已添加。"
}

# ==========================================================
# Hysteria2
# ==========================================================

add_hysteria2() {

    TAG="hysteria2"
    FILE="$INBOUND_DIR/${TAG}.json"

    ensure_certificate || return 1

    PASSWORD="$(random_password)"; [ -n "$PASSWORD" ] || { echo "密码生成失败。"; return 1; }
    PORT="$(random_port)"

    echo
    printf "Hysteria2 端口 [$PORT]: "
    read X

    [ -n "$X" ] && PORT="$X"

    echo
    printf "上行 Mbps，留空=不限制："
    read UP

    printf "下行 Mbps，留空=不限制："
    read DOWN

    if [ -n "$UP" ] && [ -n "$DOWN" ]; then

        SPEED="
  \"up_mbps\": $UP,
  \"down_mbps\": $DOWN,"

    else
        SPEED=""
    fi

    cat > "$FILE" <<EOF
{
  "type": "hysteria2",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,$SPEED
  "users": [
    {
      "name": "user1",
      "password": "$PASSWORD"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "alpn": [
      "h3"
    ],
    "min_version": "1.2",
    "certificate_path": "$CERT_DIR/www.bing.com.crt",
    "key_path": "$CERT_DIR/www.bing.com.key"
  }
}
EOF

    # 修正无 SPEED 时可能产生的逗号问题
    sed -i 's/"listen_port": \([0-9]*\),  \{0,1\}/"listen_port": \1,/' "$FILE"

    save_info "$TAG" \
        "PASSWORD=$PASSWORD" \
        "PORT=$PORT" \
        "UP=$UP" \
        "DOWN=$DOWN"

    append_order "$(basename "$FILE")"

    echo "Hysteria2 已添加。"
}

# ==========================================================
# Save metadata
# ==========================================================

save_info() {

    TAG="$1"
    shift

    DIR="$BASE/info"
    mkdir -p "$DIR"

    FILE="$DIR/$TAG"

    : > "$FILE"

    while [ "$#" -gt 0 ]; do
        printf '%s\n' "$1" >> "$FILE"
        shift
    done

    chmod 600 "$FILE"
}

append_order() {

    ORDER="$BASE/order"

    [ -f "$ORDER" ] || : > "$ORDER"

    if ! grep -qxF "$1" "$ORDER"; then
        printf '%s\n' "$1" >> "$ORDER"
    fi
}

ensure_order() {

    ORDER="$BASE/order"
    TMPO="$BASE/order.tmp"

    : > "$TMPO"

    if [ -f "$ORDER" ]; then

        while IFS= read -r FNAME; do

            [ -n "$FNAME" ] || continue

            [ -f "$INBOUND_DIR/$FNAME" ] || continue

            grep -qxF "$FNAME" "$TMPO" || printf '%s\n' "$FNAME" >> "$TMPO"

        done < "$ORDER"
    fi

    for F in "$INBOUND_DIR"/*.json; do

        [ -f "$F" ] || continue

        FNAME="$(basename "$F")"

        grep -qxF "$FNAME" "$TMPO" || printf '%s\n' "$FNAME" >> "$TMPO"
    done

    mv "$TMPO" "$ORDER"
}

find_tag_by_number() {

    n=0

    if [ -f "$BASE/order" ]; then

        while IFS= read -r FNAME; do

            [ -n "$FNAME" ] || continue

            FILE="$INBOUND_DIR/$FNAME"

            [ -f "$FILE" ] || continue

            n=$((n+1))

            if [ "$n" = "$1" ]; then
                jq -r '.tag' "$FILE"
                return 0
            fi

        done < "$BASE/order"
    fi

    for FILE in "$INBOUND_DIR"/*.json; do

        [ -f "$FILE" ] || continue

        FNAME="$(basename "$FILE")"

        if [ -f "$BASE/order" ] && grep -qxF "$FNAME" "$BASE/order"; then
            continue
        fi

        n=$((n+1))

        if [ "$n" = "$1" ]; then
            jq -r '.tag' "$FILE"
            return 0
        fi
    done

    return 1
}

# ==========================================================
# AnyReality (AnyTLS + REALITY)
# ==========================================================

add_anyreality() {

    TAG="anyreality"
    FILE="$INBOUND_DIR/${TAG}.json"

    if [ -f "$FILE" ]; then
        echo "该配置已经存在。"
        return
    fi

    UUID="$(generate_uuid)"; [ -n "$UUID" ] || { echo "UUID 生成失败。"; return 1; }
    generate_reality || return 1

    PORT=30443
    PASSWORD="$UUID"
    SNI="itunes.apple.com"

    echo
    echo "默认参数（自动生成）："
    echo "  端口      : 30443"
    echo "  密码      : $PASSWORD"
    echo "  SNI       : itunes.apple.com"
    echo "  PrivateKey: $PRIVATE_KEY"
    echo "  PublicKey : $PUBLIC_KEY"
    echo "  ShortID   : $SHORT_ID"
    echo
    echo "直接回车使用默认值，也可以修改。"
    echo

    printf "AnyReality 端口 [30443]: "
    read X
    [ -n "$X" ] && PORT="$X"

    printf "密码 [自动生成的 UUID]: "
    read X
    [ -n "$X" ] && PASSWORD="$X"

    printf "SNI [itunes.apple.com]: "
    read X
    [ -n "$X" ] && SNI="$X"

    echo
    echo "如果修改了私钥，请先用 sing-box generate reality-keypair 生成新密钥对，"
    echo "再分别填入对应的私钥和公钥。"
    echo

    printf "REALITY 私钥 [$PRIVATE_KEY]: "
    read X
    [ -n "$X" ] && PRIVATE_KEY="$X"

    printf "REALITY 公钥（对应上面的私钥）[$PUBLIC_KEY]: "
    read X
    [ -n "$X" ] && PUBLIC_KEY="$X"

    printf "ShortID [$SHORT_ID]: "
    read X
    [ -n "$X" ] && SHORT_ID="$X"

    cat > "$FILE" <<EOF
{
  "type": "anytls",
  "tag": "$TAG",
  "listen": "::",
  "listen_port": $PORT,
  "users": [
    {
      "name": "user",
      "password": "$PASSWORD"
    }
  ],
  "padding_scheme": [
    "stop=8",
    "0=30-30",
    "1=100-400",
    "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
    "3=9-9,500-1000",
    "4=500-1000",
    "5=500-1000",
    "6=500-1000",
    "7=500-1000"
  ],
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$SNI",
        "server_port": 443
      },
      "private_key": "$PRIVATE_KEY",
      "short_id": "$SHORT_ID"
    }
  }
}
EOF

    save_info "$TAG" \
        "PASSWORD=$PASSWORD" \
        "SNI=$SNI" \
        "PORT=$PORT" \
        "PUBLIC_KEY=$PUBLIC_KEY" \
        "SHORT_ID=$SHORT_ID"

    append_order "$(basename "$FILE")"

    echo
    echo "AnyReality 已添加。"
    echo "客户端 PublicKey：$PUBLIC_KEY"
}

# ==========================================================
# Rebuild config
# ==========================================================

rebuild_config() {

    mkdir -p "$INBOUND_DIR"

    ensure_order

    TMP="$BASE/config.tmp.json"
    INLIST="$BASE/inbounds.list.json"

    if ls "$INBOUND_DIR"/*.json >/dev/null 2>&1; then

        jq -s '.' "$INBOUND_DIR"/*.json > "$INLIST" 2>/dev/null || {
            echo "配置合并失败（inbounds 解析错误）。"
            return 1
        }

    else

        echo "配置合并失败（没有配置文件）。"
        return 1
    fi

    if [ -f "$BASE/dns.json" ]; then

        jq -n \
            --slurpfile dns "$BASE/dns.json" \
            --slurpfile in "$INLIST" \
            '{
                log: {
                    level: "warn",
                    output: "/dev/null",
                    timestamp: true
                },
                dns: $dns[0].dns,
                inbounds: $in[0],
                outbounds: [
                    {
                        type: "direct",
                        tag: "direct"
                    }
                ]
            }' > "$TMP" 2>/dev/null

    else

        jq -n \
            --slurpfile in "$INLIST" \
            '{
                log: {
                    level: "warn",
                    output: "/dev/null",
                    timestamp: true
                },
                inbounds: $in[0],
                outbounds: [
                    {
                        type: "direct",
                        tag: "direct"
                    }
                ]
            }' > "$TMP" 2>/dev/null
    fi

    rm -f "$INLIST"

    if [ ! -s "$TMP" ]; then
        echo "配置合并失败。"
        return 1
    fi

    if ! "$BIN" check -c "$TMP"; then
        rm -f "$TMP"
        echo "配置校验失败，已保留原配置。"
        return 1
    fi

    mv "$TMP" "$CONFIG"

    chmod 600 "$CONFIG"
}

# ==========================================================
# Service
# ==========================================================

install_service() {

    if [ "$OS_ID" = "alpine" ]; then

        # Alpine 64MB 内存下 OpenRC 容易出问题，改用 crontab 开机自启（参考部署指南 2.5）
        rm -f /etc/init.d/sing-box

        CRON_LINE="@reboot GOMEMLIMIT=24MiB $BIN run -c $CONFIG > /dev/null 2>&1 &"
        WATCHDOG="* * * * * pgrep -f sing-box[.]run >/dev/null 2>&1 || { GOMEMLIMIT=24MiB $BIN run -c $CONFIG > /dev/null 2>&1 & sleep 2; echo 800 > /proc/\$(pgrep -f sing-box[.]run | head -1)/oom_score_adj 2>/dev/null; }"

        (
            crontab -l 2>/dev/null | grep -v '@reboot.*sing-box run' | grep -vF 'pgrep -f sing-box.run' | grep -vF 'pgrep -f sing-box[.]run' || true
            printf '%s\n%s\n' "$CRON_LINE" "$WATCHDOG"
        ) | crontab -

        # Alpine 容器常无 crond 服务且未运行——不拉起的话 crontab 全部失效
        if command_exists crond && ! pgrep -f crond >/dev/null 2>&1; then
            crond 2>/dev/null || true
        fi

        # 开机自启不依赖 crond：local 服务开机执行（拉起 crond + sing-box）
        mkdir -p /etc/local.d

        cat > /etc/local.d/sing-box.start <<SDEOF
#!/bin/sh
if command -v crond >/dev/null 2>&1 && ! pgrep -f crond >/dev/null 2>&1; then
    crond 2>/dev/null
fi
GOMEMLIMIT=24MiB $BIN run -c $CONFIG > /dev/null 2>&1 &
sleep 2
echo 800 > /proc/\$(pgrep -f sing-box[.]run | head -1)/oom_score_adj 2>/dev/null
SDEOF

        chmod +x /etc/local.d/sing-box.start

        # local.d 只有 local 服务被启用才会执行；crontab 依赖 crond 运行——都加入开机
        [ -x /etc/init.d/local ] && rc-update add local default >/dev/null 2>&1
        [ -x /etc/init.d/crond ] && rc-update add crond default >/dev/null 2>&1

        echo "[+] 已配置 crontab 开机自启："
        crontab -l 2>/dev/null | grep '@reboot.*sing-box run' || true

    else

        cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box proxy service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
    fi
}

start_service() {

    if [ "$OS_ID" = "alpine" ]; then
        kill $(pgrep -f sing-box[.]run) 2>/dev/null 2>/dev/null || true
        sleep 1
        GOMEMLIMIT=24MiB nohup "$BIN" run -c "$CONFIG" > /dev/null 2>&1 &
        sleep 1
    else
        systemctl restart sing-box
    fi
}

stop_service() {

    if [ "$OS_ID" = "alpine" ]; then
        kill $(pgrep -f sing-box[.]run) 2>/dev/null 2>/dev/null || true
    else
        systemctl stop sing-box
    fi
}

service_status() {

    if [ "$OS_ID" = "alpine" ]; then
        if pgrep -f sing-box[.]run >/dev/null 2>&1; then
            echo "sing-box 运行中："
            pgrep -a sing-box
        else
            echo "sing-box 未运行。"
        fi
    else
        systemctl status sing-box --no-pager
    fi
}

# ==========================================================
# Show configs
# ==========================================================

list_configs() {

    echo
    echo "=========================================="
    echo " 当前配置"
    echo "=========================================="

    found=0
    n=0

    if [ -f "$BASE/order" ]; then

        while IFS= read -r FNAME; do

            [ -n "$FNAME" ] || continue

            FILE="$INBOUND_DIR/$FNAME"

            [ -f "$FILE" ] || continue

            found=1
            n=$((n+1))

            TAG="$(jq -r '.tag' "$FILE")"
            TYPE="$(jq -r '.type' "$FILE")"
            PORT="$(jq -r '.listen_port' "$FILE")"

            printf "%d.%s | %s | port=%s\n" \
                "$n" "$TAG" "$TYPE" "$PORT"

        done < "$BASE/order"
    fi

    for FILE in "$INBOUND_DIR"/*.json; do

        [ -f "$FILE" ] || continue

        FNAME="$(basename "$FILE")"

        if [ -f "$BASE/order" ] && grep -qxF "$FNAME" "$BASE/order"; then
            continue
        fi

        found=1
        n=$((n+1))

        TAG="$(jq -r '.tag' "$FILE")"
        TYPE="$(jq -r '.type' "$FILE")"
        PORT="$(jq -r '.listen_port' "$FILE")"

        printf "%d.%s | %s | port=%s\n" \
            "$n" "$TAG" "$TYPE" "$PORT"
    done

    [ "$found" = "1" ] || echo "暂无配置。"
}

# ==========================================================
# Add all protocols
# ==========================================================

add_all_configs() {

    add_vless_reality
    add_shadowsocks
    add_tuic
    add_anytls
    add_hysteria2
    add_anyreality
    add_vless_reality_free
}

# ==========================================================
# Run multi selection (e.g. 1,4,6 / 1，4，6)
# ==========================================================

run_selection() {

    SELECTION="$1"

    for ITEM in $(printf '%s' "$SELECTION" | sed 's/，/,/g' | tr ',' ' '); do

        [ -n "$ITEM" ] || continue

        case "$ITEM" in
            1) add_vless_reality ;;
            2) add_shadowsocks ;;
            3) add_tuic ;;
            4) add_anytls ;;
            5) add_hysteria2 ;;
            6) add_anyreality ;;
            7) add_vless_reality_free ;;
            8) add_all_configs ;;
            *) echo "无效选项：$ITEM（已跳过）" ;;
        esac
    done
}

# ==========================================================
# Add configuration
# ==========================================================

add_config_menu() {

    echo
    echo "=========================================="
    echo " 添加配置"
    echo "=========================================="
    echo
    echo "1. VLESS + REALITY"
    echo "2. Shadowsocks"
    echo "3. TUIC"
    echo "4. AnyTLS"
    echo "5. Hysteria2"
    echo "6. AnyReality（AnyTLS + REALITY）"
    echo "7. VLESS + REALITY（免流）"
    echo "8. 全部添加"
    echo

    printf "请选择（可多选，如 1,4,6）："
    read N

    [ -n "$N" ] || {
        echo "未选择。"
        return
    }

    run_selection "$N"

    if rebuild_config; then
        start_service
    else
        echo "配置未生效，服务保持原状。"
    fi
}

# ==========================================================
# Delete configuration
# ==========================================================

delete_config() {

    list_configs

    echo
    printf "输入编号或 Tag："
    read INPUT

    [ -n "$INPUT" ] || return

    case "$INPUT" in
        ''|*[!0-9]*) TAG="$INPUT" ;;
        *) TAG="$(find_tag_by_number "$INPUT")" ;;
    esac

    [ -n "$TAG" ] || {
        echo "没有找到该配置。"
        return
    }

    for FILE in "$INBOUND_DIR"/*.json; do

        [ -f "$FILE" ] || continue

        CURRENT="$(jq -r '.tag' "$FILE")"

        if [ "$CURRENT" = "$TAG" ]; then

            rm -f "$FILE"
            rm -f "$BASE/info/$TAG"

            if [ -f "$BASE/order" ]; then
                sed -i "\|^$(basename "$FILE")$|d" "$BASE/order"
            fi

            echo "已删除：$TAG"

            rebuild_config
            start_service

            return
        fi
    done

    echo "没有找到该配置。"
}

# ==========================================================
# View configuration
# ==========================================================

view_config() {

    list_configs

    echo
    printf "输入编号或 Tag："
    read INPUT

    [ -n "$INPUT" ] || return

    case "$INPUT" in
        ''|*[!0-9]*) TAG="$INPUT" ;;
        *) TAG="$(find_tag_by_number "$INPUT")" ;;
    esac

    [ -n "$TAG" ] || {
        echo "没有找到。"
        return
    }

    for FILE in "$INBOUND_DIR"/*.json; do

        [ -f "$FILE" ] || continue

        CURRENT="$(jq -r '.tag' "$FILE")"

        if [ "$CURRENT" = "$TAG" ]; then
            echo
            jq . "$FILE"
            return
        fi
    done

    echo "没有找到。"
}

# ==========================================================
# Edit configuration
# ==========================================================

edit_config() {

    list_configs

    echo
    printf "输入编号或 Tag："
    read INPUT

    [ -n "$INPUT" ] || return

    case "$INPUT" in
        ''|*[!0-9]*) TAG="$INPUT" ;;
        *) TAG="$(find_tag_by_number "$INPUT")" ;;
    esac

    [ -n "$TAG" ] || {
        echo "没有找到。"
        return
    }

    FOUND=""

    for FILE in "$INBOUND_DIR"/*.json; do

        [ -f "$FILE" ] || continue

        if [ "$(jq -r '.tag' "$FILE")" = "$TAG" ]; then
            FOUND=1
            break
        fi
    done

    if [ -z "$FOUND" ]; then
        echo "没有找到。"
        return
    fi

    if [ -x /usr/local/bin/sing-box-edit-config ]; then
        /usr/local/bin/sing-box-edit-config "$TAG"
    else
        echo "交互编辑器未安装，请重新运行安装脚本，或使用 vi 直接编辑。"
        for FILE in "$INBOUND_DIR"/*.json; do
            [ -f "$FILE" ] || continue
            if [ "$(jq -r '.tag' "$FILE")" = "$TAG" ]; then
                vi "$FILE"
                break
            fi
        done
    fi

    rebuild_config
    start_service
}

# ==========================================================
# Share links
# ==========================================================

get_ip() {

    IP="$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"

    [ -n "$IP" ] || IP="YOUR_SERVER_IP"
}

generate_links() {

    mkdir -p "$LINK_DIR"

    get_ip

    COUNTRY="US"

    if [ -f "$INFO" ]; then
        COUNTRY="$(sed -n 's/^COUNTRY=//p' "$INFO")"
    fi

    rm -f "$LINK_DIR"/*.txt

    for FILE in "$INBOUND_DIR"/*.json; do

        [ -f "$FILE" ] || continue

        TYPE="$(jq -r '.type' "$FILE")"
        TAG="$(jq -r '.tag' "$FILE")"
        PORT="$(jq -r '.listen_port' "$FILE")"

        case "$TAG" in
            vless-reality) NAME="reality" ;;
            vless-reality-free|vless-reality-免流) NAME="reality免流" ;;
            shadowsocks) NAME="shadowsocks" ;;
            tuic) NAME="tuic" ;;
            anytls) NAME="anytls" ;;
            hysteria2) NAME="hysteria2" ;;
            anyreality) NAME="anyreality" ;;
            *) NAME="$TAG" ;;
        esac

        REMARK="${COUNTRY}-${NAME}"

        case "$TYPE" in

        vless)

            UUID="$(jq -r '.users[0].uuid' "$FILE")"
            SNI="$(jq -r '.tls.server_name' "$FILE")"

            if jq -e '.tls.reality.enabled == true' "$FILE" >/dev/null 2>&1; then

                SID="$(
                    jq -r '.tls.reality.short_id[0]' "$FILE"
                )"

                INFOFILE="$BASE/info/$TAG"

                if [ -f "$INFOFILE" ]; then
                    PBK="$(sed -n 's/^PUBLIC_KEY=//p' "$INFOFILE")"
                else
                    PBK=""
                fi

                LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp&headerType=none#${REMARK}"

                echo "$LINK" > "$LINK_DIR/$TAG.txt"
            fi
            ;;

        shadowsocks)

            METHOD="$(jq -r '.method' "$FILE")"
            PASSWORD="$(jq -r '.password' "$FILE")"

            PASSWORD_ENC="$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"

            echo "ss://${METHOD}:${PASSWORD_ENC}@${IP}:${PORT}#${REMARK}" \
                > "$LINK_DIR/$TAG.txt"
            ;;

        anytls)

            PASSWORD="$(jq -r '.users[0].password' "$FILE")"

            if jq -e '.tls.reality.enabled == true' "$FILE" >/dev/null 2>&1; then

                SNI="$(jq -r '.tls.server_name' "$FILE")"

                SID="$(jq -r '.tls.reality.short_id | if type == "array" then .[0] else . end' "$FILE")"

                INFOFILE="$BASE/info/$TAG"

                if [ -f "$INFOFILE" ]; then
                    PBK="$(sed -n 's/^PUBLIC_KEY=//p' "$INFOFILE")"
                else
                    PBK=""
                fi

                {
                    echo "protocol=anytls"
                    echo "server=${IP}"
                    echo "port=${PORT}"
                    echo "password=${PASSWORD}"
                    echo "tls=enabled"
                    echo "sni=${SNI}"
                    echo "security=reality"
                    echo "pbk=${PBK}"
                    echo "sid=${SID}"
                    echo "fp=chrome"
                    echo "remark=${REMARK}"
                } > "$LINK_DIR/$TAG.txt"

            else

                {
                    echo "protocol=anytls"
                    echo "server=${IP}"
                    echo "port=${PORT}"
                    echo "password=${PASSWORD}"
                    echo "sni=www.bing.com"
                    echo "allow_insecure=true"
                    echo "remark=${REMARK}"
                } > "$LINK_DIR/$TAG.txt"

            fi
            ;;

        hysteria2)

            PASSWORD="$(jq -r '.users[0].password' "$FILE")"

            PASSWORD_ENC="$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"

            echo "hysteria2://${PASSWORD_ENC}@${IP}:${PORT}/?sni=www.bing.com&insecure=1#${REMARK}" \
                > "$LINK_DIR/$TAG.txt"
            ;;

        tuic)

            UUID="$(jq -r '.users[0].uuid' "$FILE")"
            PASSWORD="$(jq -r '.users[0].password' "$FILE")"

            PASSWORD_ENC="$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"

            echo "tuic://${UUID}:${PASSWORD_ENC}@${IP}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&allow_insecure=1#${REMARK}" \
                > "$LINK_DIR/$TAG.txt"
            ;;

        esac
    done
}

show_links() {

    generate_links

    echo
    echo "=========================================="
    echo " 分享信息"
    echo "=========================================="

    for FILE in "$LINK_DIR"/*.txt; do

        [ -f "$FILE" ] || continue

        echo
        echo "----- $(basename "$FILE") -----"
        cat "$FILE"
        echo
    done

    if [ -f "$CERT_DIR/www.bing.com.crt" ]; then

        echo
        echo "===== TLS 固定证书（可选，替代跳过证书验证）====="
        echo "v2rayN：节点设置 → 固定证书 → 获取证书（或粘贴下方 PEM）"
        echo "设置后会自动禁用跳过证书验证，SNI 保持 www.bing.com 不变："
        echo
        cat "$CERT_DIR/www.bing.com.crt"
    fi
}

# ==========================================================
# Update
# ==========================================================

update_singbox() {

    echo
    echo "更新 sing-box..."

    stop_service || true

    install_singbox

    rebuild_config

    start_service

    echo
    echo "更新完成。"
}

# ==========================================================
# Uninstall
# ==========================================================

uninstall_all() {

    echo
    echo "=========================================="
    echo " 卸载"
    echo "=========================================="

    ask_yes_no "确认卸载？" || {
        echo "取消。"
        return
    }

    stop_service || true

    if [ "$OS_ID" = "alpine" ]; then
        rm -f /etc/init.d/sing-box
        crontab -l 2>/dev/null | grep -v '@reboot.*sing-box run' | crontab - 2>/dev/null || true
    else
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi

    rm -f "$BIN"
    rm -rf "$BASE"
    rm -f /usr/local/bin/lsb
    rm -f /usr/local/bin/singbox
    rm -f /usr/local/bin/sing-box-edit-config

    echo
    echo "sing-box 已卸载。"
    exit 0
}

# ==========================================================
# Management panel
# ==========================================================

management_panel() {

    while :; do

        clear

        echo "================================================"
        echo "             sing-box 管理面板"
        echo "================================================"
        echo

        VER="$(cat "$BASE/sing-box-version" 2>/dev/null)"
        if [ -n "$VER" ]; then
            echo "sing-box version $VER"
        else
            "$BIN" version 2>/dev/null | head -n 1
        fi

        echo

        list_configs

        echo
        echo "------------------------------------------------"
        echo "1. 添加配置"
        echo "2. 更改配置"
        echo "3. 查看配置"
        echo "4. 删除配置"
        echo "5. 查看分享链接"
        echo "6. 服务状态"
        echo "7. 启动"
        echo "8. 停止"
        echo "9. 重启"
        echo "10. 校验配置"
        echo "11. 查看日志"
        echo "12. DNS 设置"
        echo "13. BBR 状态"
        echo "14. 更新 sing-box"
        echo "15. 卸载"
        echo "0. 退出"
        echo "------------------------------------------------"
        echo

        printf "请选择："
        read MENU

        case "$MENU" in

        1)
            add_config_menu
            pause
            ;;

        2)
            edit_config
            pause
            ;;

        3)
            view_config
            pause
            ;;

        4)
            delete_config
            pause
            ;;

        5)
            show_links
            pause
            ;;

        6)
            service_status
            pause
            ;;

        7)
            start_service
            pause
            ;;

        8)
            stop_service
            pause
            ;;

        9)
            rebuild_config
            start_service
            pause
            ;;

        10)
            "$BIN" check -c "$CONFIG"
            pause
            ;;

        11)

            if command_exists journalctl; then
                journalctl -u sing-box --no-pager -n 100
            elif [ -f /var/log/sing-box.log ]; then
                tail -n 100 /var/log/sing-box.log
            else
                echo "没有日志。"
            fi

            pause
            ;;

        12)
            configure_dns
            rebuild_config
            start_service
            pause
            ;;

        13)
            echo
            cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
            echo
            cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true
            pause
            ;;

        14)
            update_singbox
            pause
            ;;

        15)
            uninstall_all
            ;;

        0)
            exit 0
            ;;

        *)
            echo "无效选项。"
            pause
            ;;
        esac
    done
}

# ==========================================================
# Install lsb
# ==========================================================

install_lsb() {

    cat > /usr/local/bin/lsb <<'EOF'
#!/bin/sh

exec /usr/local/bin/sing-box-manager
EOF

    chmod 755 /usr/local/bin/lsb

    cat > /usr/local/bin/singbox <<'EOF'
#!/bin/sh

exec /usr/local/bin/sing-box-manager
EOF

    chmod 755 /usr/local/bin/singbox

    cat > /usr/local/bin/sing-box-edit-config <<'EOF'
#!/bin/sh

BASE="/etc/sing-box"
INBOUND_DIR="$BASE/inbounds"

TAG="$1"

[ -n "$TAG" ] || exit 1

FILE=""

for F in "$INBOUND_DIR"/*.json; do

    [ -f "$F" ] || continue

    if [ "$(jq -r '.tag' "$F")" = "$TAG" ]; then
        FILE="$F"
        break
    fi
done

[ -n "$FILE" ] || {
    echo "没有找到该配置。"
    exit 1
}

set_info() {

    KEY="${2%%=*}"
    INFOFILE="$BASE/info/$1"

    mkdir -p "$BASE/info"

    if [ -f "$INFOFILE" ] && grep -q "^$KEY=" "$INFOFILE"; then
        sed -i "s|^$KEY=.*|$2|" "$INFOFILE"
    else
        printf '%s\n' "$2" >> "$INFOFILE"
    fi
}

read_required() {

    REQ=""

    while :; do
        printf "%s" "$1"
        read REQ
        [ -n "$REQ" ] && return 0
        echo "输入不能为空，请重新输入。"
    done
}

read_port() {

    REQ=""

    while :; do
        printf "%s" "$1"
        read REQ
        case "$REQ" in
            ''|*[!0-9]*) echo "端口必须是数字，请重新输入。" ;;
            *) return 0 ;;
        esac
    done
}

read_shortid() {

    REQ=""

    while :; do
        printf "%s" "$1"
        read REQ
        case "$REQ" in
            ''|*[!0-9a-fA-F]*) echo "ShortID 必须是十六进制字符，请重新输入。" ;;
            *) return 0 ;;
        esac
    done
}

TYPE="$(jq -r '.type' "$FILE")"

while :; do

    echo
    echo "=========================================="
    echo " 修改配置：$TAG（$TYPE）"
    echo "=========================================="

    PORT="$(jq -r '.listen_port' "$FILE")"
    UUID="$(jq -r '.users[0].uuid // empty' "$FILE")"
    PASS="$(jq -r '.users[0].password // .password // empty' "$FILE")"
    SNI="$(jq -r '.tls.server_name // empty' "$FILE")"
    PRIV="$(jq -r '.tls.reality.private_key // empty' "$FILE")"
    SID="$(jq -r '.tls.reality.short_id | if type == "array" then .[0] else . end' "$FILE")"

    echo
    echo "  端口      : $PORT"
    [ -n "$UUID" ] && echo "  UUID      : $UUID"
    [ -n "$PASS" ] && echo "  密码      : $PASS"
    [ -n "$SNI" ] && echo "  SNI       : $SNI"
    [ -n "$PRIV" ] && echo "  PrivateKey: $PRIV"
    [ -n "$SID" ] && echo "  ShortID   : $SID"

    echo
    echo "可修改字段："
    echo "1. 端口"

    if [ "$TYPE" = "vless" ] || [ "$TYPE" = "tuic" ]; then
        echo "2. UUID"
    fi

    case "$TYPE" in
        anytls|anyreality|hysteria2|shadowsocks|tuic)
            echo "3. 密码"
            ;;
    esac

    case "$TYPE" in
        vless|anytls|anyreality|hysteria2|tuic)
            echo "4. SNI"
            ;;
    esac

    if [ "$TYPE" = "vless" ] || [ "$TYPE" = "anyreality" ]; then
        echo "5. REALITY 私钥 + 公钥"
        echo "6. ShortID"
    fi

    echo "0. 完成并应用"
    echo
    printf "请选择 [0]: "
    read CH

    case "$CH" in

        1)
            read_port "新端口 [$PORT]: "
            NEW="$REQ"
            jq --arg v "$NEW" '.listen_port = ($v | tonumber)' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
            mv "$FILE.tmp" "$FILE"
            set_info "$TAG" "PORT=$NEW"
            ;;

        2)
            if [ "$TYPE" = "vless" ] || [ "$TYPE" = "tuic" ]; then
                read_required "新 UUID [$UUID]: "
                NEW="$REQ"
                jq --arg v "$NEW" '.users[0].uuid = $v' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                mv "$FILE.tmp" "$FILE"
                set_info "$TAG" "UUID=$NEW"
            fi
            ;;

        3)
            case "$TYPE" in
                shadowsocks)
                    read_required "新密码 [$PASS]: "
                    NEW="$REQ"
                    jq --arg v "$NEW" '.password = $v' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                    mv "$FILE.tmp" "$FILE"
                    set_info "$TAG" "PASSWORD=$NEW"
                    ;;
                anytls|anyreality|hysteria2|tuic)
                    read_required "新密码 [$PASS]: "
                    NEW="$REQ"
                    jq --arg v "$NEW" '.users[0].password = $v' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                    mv "$FILE.tmp" "$FILE"
                    set_info "$TAG" "PASSWORD=$NEW"
                    ;;
            esac
            ;;

        4)
            case "$TYPE" in
                vless|anytls|anyreality|hysteria2|tuic)
                    read_required "新 SNI [$SNI]: "
                    NEW="$REQ"
                    jq --arg v "$NEW" '
                        .tls.server_name = $v |
                        if .tls.reality then .tls.reality.handshake.server = $v else . end
                    ' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                    mv "$FILE.tmp" "$FILE"
                    set_info "$TAG" "SNI=$NEW"
                    ;;
            esac
            ;;

        5)
            if [ "$TYPE" = "vless" ] || [ "$TYPE" = "anyreality" ]; then
                echo
                echo "提示：先用 sing-box generate reality-keypair 生成新密钥对，"
                echo "然后分别输入私钥和公钥。"
                echo
                read_required "新 PrivateKey："
                NEWPK="$REQ"
                read_required "对应的 PublicKey："
                NEWPBK="$REQ"
                jq --arg v "$NEWPK" '.tls.reality.private_key = $v' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                mv "$FILE.tmp" "$FILE"
                set_info "$TAG" "PUBLIC_KEY=$NEWPBK"
            fi
            ;;

        6)
            if [ "$TYPE" = "vless" ] || [ "$TYPE" = "anyreality" ]; then
                read_shortid "新 ShortID [$SID]: "
                NEW="$REQ"
                if [ "$TYPE" = "vless" ]; then
                    jq --arg v "$NEW" '.tls.reality.short_id = [$v]' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                else
                    jq --arg v "$NEW" '.tls.reality.short_id = $v' "$FILE" > "$FILE.tmp" 2>/dev/null || continue
                fi
                mv "$FILE.tmp" "$FILE"
                set_info "$TAG" "SHORT_ID=$NEW"
            fi
            ;;

        0|"")
            break
            ;;

        *)
            echo "无效选项。"
            ;;
    esac
done

echo
echo "配置已更新：$TAG"
exit 0
EOF

    chmod 755 /usr/local/bin/sing-box-edit-config

    cat > /usr/local/bin/sing-box-manager <<'EOF'
#!/bin/sh

BASE="/etc/sing-box"
BIN="/usr/local/bin/sing-box"

# 限制 Go 堆内存，避免小内存机器上 sing-box 启动/运行时触发 OOM
export GOMEMLIMIT=24MiB

random_port() {
    awk 'BEGIN{srand(); print int(20000+rand()*40000)}'
}

pause() {
    echo
    printf "按 Enter 继续..."
    read x
}

ask_yes_no() {

    printf "%s [y/N]: " "$1"
    read ANSWER

    case "$ANSWER" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

work_dir() {
    # /tmp 在小内存机器上是 tmpfs（内存盘），大文件放进去会触发 OOM 杀掉 SSH 会话
    for d in /var/tmp /root /usr/local/src; do
        mkdir -p "$d" 2>/dev/null || continue
        case "$(df -P "$d" 2>/dev/null | tail -n 1 | awk '{print $1}')" in
            tmpfs*) ;;
            *)
                echo "$d/$1"
                return 0
                ;;
        esac
    done

    echo "/root/$1"
}

rate_opt() {
    # 项目默认目标是 64MB 小内存 Alpine NAT 机，不做机器探测（NAT 机内存
    # 读数不准）。限速压住解压脏页的生成速率，避免触发 OOM
    echo "--limit-rate=2m"
}

enable_bbr() {

    if [ ! -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
        echo "当前系统无法检测 BBR。"
        return
    fi

    AVAILABLE="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    CURRENT="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"

    echo "当前：$CURRENT"
    echo "可用：$AVAILABLE"

    case " $AVAILABLE " in
        *" bbr "*)
            echo "[+] 检测到 BBR，启用。"

            mkdir -p /etc/sysctl.d

            cat > /etc/sysctl.d/99-sing-box-bbr.conf <<BBREOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF

            sysctl --system >/dev/null 2>&1 || true
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

            echo "[+] BBR 已启用（立即生效 + 开机持久化）。"
            ;;
        *)
            echo "当前内核不支持 BBR，不修改。"
            ;;
    esac
}

list_configs() {

    echo
    echo "当前配置："

    found=0
    n=0

    if [ -f "$BASE/order" ]; then

        while IFS= read -r FNAME; do

            [ -n "$FNAME" ] || continue

            FILE="$BASE/inbounds/$FNAME"

            [ -f "$FILE" ] || continue

            found=1
            n=$((n+1))

            jq -r --arg n "$n" '"\($n).\(.tag) | \(.type) | port=\(.listen_port)"' "$FILE"

        done < "$BASE/order"
    fi

    for FILE in "$BASE/inbounds"/*.json; do

        [ -f "$FILE" ] || continue

        FNAME="$(basename "$FILE")"

        if [ -f "$BASE/order" ] && grep -qxF "$FNAME" "$BASE/order"; then
            continue
        fi

        found=1
        n=$((n+1))

        jq -r --arg n "$n" '"\($n).\(.tag) | \(.type) | port=\(.listen_port)"' "$FILE"
    done

    [ "$found" = "1" ] || echo "  暂无"
}

find_tag_by_number() {

    n=0

    if [ -f "$BASE/order" ]; then

        while IFS= read -r FNAME; do

            [ -n "$FNAME" ] || continue

            FILE="$BASE/inbounds/$FNAME"

            [ -f "$FILE" ] || continue

            n=$((n+1))

            if [ "$n" = "$1" ]; then
                jq -r '.tag' "$FILE"
                return 0
            fi

        done < "$BASE/order"
    fi

    for FILE in "$BASE/inbounds"/*.json; do

        [ -f "$FILE" ] || continue

        FNAME="$(basename "$FILE")"

        if [ -f "$BASE/order" ] && grep -qxF "$FNAME" "$BASE/order"; then
            continue
        fi

        n=$((n+1))

        if [ "$n" = "$1" ]; then
            jq -r '.tag' "$FILE"
            return 0
        fi
    done

    return 1
}

service_start() {

    if command -v systemctl >/dev/null 2>&1; then
        systemctl start sing-box
    else
        GOMEMLIMIT=24MiB nohup /usr/local/bin/sing-box run -c /etc/sing-box/config.json > /dev/null 2>&1 &
    fi
}

service_stop() {

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop sing-box
    else
        kill $(pgrep -f sing-box[.]run) 2>/dev/null 2>/dev/null || true
    fi
}

service_restart() {

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart sing-box
    else
        kill $(pgrep -f sing-box[.]run) 2>/dev/null 2>/dev/null || true
        sleep 1
        GOMEMLIMIT=24MiB nohup /usr/local/bin/sing-box run -c /etc/sing-box/config.json > /dev/null 2>&1 &
    fi
}

service_status() {

    if command -v systemctl >/dev/null 2>&1; then
        systemctl status sing-box --no-pager
    else
        if pgrep -f sing-box[.]run >/dev/null 2>&1; then
            echo "sing-box 运行中："
            pgrep -a sing-box
        else
            echo "sing-box 未运行。"
        fi
    fi
}

ensure_order() {

    ORDER="$BASE/order"
    TMPO="$BASE/order.tmp"

    : > "$TMPO"

    if [ -f "$ORDER" ]; then

        while IFS= read -r FNAME; do

            [ -n "$FNAME" ] || continue

            [ -f "$BASE/inbounds/$FNAME" ] || continue

            grep -qxF "$FNAME" "$TMPO" || printf '%s\n' "$FNAME" >> "$TMPO"

        done < "$ORDER"
    fi

    for F in "$BASE/inbounds"/*.json; do

        [ -f "$F" ] || continue

        FNAME="$(basename "$F")"

        grep -qxF "$FNAME" "$TMPO" || printf '%s\n' "$FNAME" >> "$TMPO"
    done

    mv "$TMPO" "$ORDER"
}

rebuild() {

    ensure_order

    INLIST="$BASE/inbounds.list.json"

    if ls "$BASE/inbounds"/*.json >/dev/null 2>&1; then

        jq -s '.' "$BASE/inbounds"/*.json > "$INLIST" 2>/dev/null || {
            echo "配置合并失败（inbounds 解析错误）。"
            return 1
        }

    else

        echo "配置合并失败（没有配置文件）。"
        return 1
    fi

    if [ -f "$BASE/dns.json" ]; then

        jq -n \
            --slurpfile dns "$BASE/dns.json" \
            --slurpfile in "$INLIST" \
            '{
                log: {
                    level: "warn",
                    output: "/dev/null",
                    timestamp: true
                },
                dns: $dns[0].dns,
                inbounds: $in[0],
                outbounds: [
                    {
                        type: "direct",
                        tag: "direct"
                    }
                ]
            }' > "$BASE/config.tmp.json"

    else

        jq -n \
            --slurpfile in "$INLIST" \
            '{
                log: {
                    level: "warn",
                    output: "/dev/null",
                    timestamp: true
                },
                inbounds: $in[0],
                outbounds: [
                    {
                        type: "direct",
                        tag: "direct"
                    }
                ]
            }' > "$BASE/config.tmp.json"
    fi

    rm -f "$INLIST"

    if ! "$BIN" check -c "$BASE/config.tmp.json"; then
        rm -f "$BASE/config.tmp.json"
        echo "配置校验失败，已保留原配置。"
        return 1
    fi

    mv "$BASE/config.tmp.json" "$BASE/config.json"
}

view_config() {

    list_configs

    echo
    printf "输入编号或 Tag："
    read INPUT

    [ -n "$INPUT" ] || return

    case "$INPUT" in
        ''|*[!0-9]*) TAG="$INPUT" ;;
        *) TAG="$(find_tag_by_number "$INPUT")" ;;
    esac

    [ -n "$TAG" ] || {
        echo "没有找到。"
        return
    }

    FILE=""

    for F in "$BASE/inbounds"/*.json; do
        [ -f "$F" ] || continue
        if [ "$(jq -r '.tag' "$F")" = "$TAG" ]; then
            FILE="$F"
            break
        fi
    done

    if [ -n "$FILE" ]; then
        jq . "$FILE"
    else
        echo "没有找到。"
    fi
}

delete_config() {

    list_configs

    echo
    printf "输入编号或 Tag："
    read INPUT

    [ -n "$INPUT" ] || return

    case "$INPUT" in
        ''|*[!0-9]*) TAG="$INPUT" ;;
        *) TAG="$(find_tag_by_number "$INPUT")" ;;
    esac

    [ -n "$TAG" ] || {
        echo "不存在。"
        return
    }

    FILE=""

    for F in "$BASE/inbounds"/*.json; do
        [ -f "$F" ] || continue
        if [ "$(jq -r '.tag' "$F")" = "$TAG" ]; then
            FILE="$F"
            break
        fi
    done

    if [ -f "$FILE" ]; then

        rm -f "$FILE"
        rm -f "$BASE/info/$TAG"
        rm -f "$BASE/links/$TAG.txt"

        FNAME="$(basename "$FILE")"

        if [ -f "$BASE/order" ]; then
            sed -i "\|^$FNAME$|d" "$BASE/order"
        fi

        rebuild
        service_restart

        echo "删除成功。"

    else
        echo "不存在。"
    fi
}

edit_config() {

    list_configs

    echo
    printf "输入编号或 Tag："
    read INPUT

    [ -n "$INPUT" ] || return

    case "$INPUT" in
        ''|*[!0-9]*) TAG="$INPUT" ;;
        *) TAG="$(find_tag_by_number "$INPUT")" ;;
    esac

    [ -n "$TAG" ] || {
        echo "没有找到。"
        return
    }

    if [ -x /usr/local/bin/sing-box-edit-config ]; then

        /usr/local/bin/sing-box-edit-config "$TAG" && {
            rebuild
            service_restart
        }

    else

        FILE=""

        for F in "$BASE/inbounds"/*.json; do
            [ -f "$F" ] || continue
            if [ "$(jq -r '.tag' "$F")" = "$TAG" ]; then
                FILE="$F"
                break
            fi
        done

        if [ -n "$FILE" ]; then
            vi "$FILE"
            rebuild
            service_restart
        else
            echo "不存在。"
        fi
    fi
}

show_links() {

    "$BASE/generate-links.sh"

    echo

    for FILE in "$BASE/links"/*.txt; do

        [ -f "$FILE" ] || continue

        echo
        echo "===== $(basename "$FILE") ====="
        cat "$FILE"
    done

    if [ -f "$BASE/cert/www.bing.com.crt" ]; then

        echo
        echo "===== TLS 固定证书（可选，替代跳过证书验证）====="
        echo "v2rayN：节点设置 → 固定证书 → 获取证书（或粘贴下方 PEM）"
        echo "设置后会自动禁用跳过证书验证，SNI 保持 www.bing.com 不变："
        echo
        cat "$BASE/cert/www.bing.com.crt"
    fi
}

check_updates() {

    HINT="$BASE/update-hint"
    LAST="$BASE/.last-update-check"

    NOW="$(date +%s 2>/dev/null || echo 0)"

    if [ -f "$LAST" ] && [ "$NOW" -gt 0 ]; then
        OLD="$(cat "$LAST" 2>/dev/null || echo 0)"
        if [ "$NOW" -lt $((OLD + 21600)) ]; then
            cat "$HINT" 2>/dev/null
            return
        fi
    fi

    : > "$HINT"

    LATEST_K="$(curl -fsSL --max-time 5 "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20" 2>/dev/null | jq -r '[.[] | select(.prerelease == false)][0].tag_name' 2>/dev/null | tr -d 'v')"

    CURRENT_K="$(cat "$BASE/sing-box-version" 2>/dev/null)"
    [ -n "$CURRENT_K" ] || CURRENT_K="$("$BIN" version 2>/dev/null | head -n 1 | awk '{print $3}')"

    if [ -n "$LATEST_K" ] && [ -n "$CURRENT_K" ] && [ "$LATEST_K" != "$CURRENT_K" ]; then
        echo "[!] sing-box 内核有新版本：$CURRENT_K -> $LATEST_K（选 15 更新）" >> "$HINT"
    fi

    REMOTE_SV="$(curl -fsSL --max-time 5 -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/loser641/singbox-deploy/contents/sb.sh" 2>/dev/null | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -n 1)"

    LOCAL_SV="$(cat "$BASE/script-version" 2>/dev/null)"

    if [ -n "$REMOTE_SV" ] && [ -n "$LOCAL_SV" ] && [ "$REMOTE_SV" != "$LOCAL_SV" ]; then
        echo "[!] 脚本有新版本：$LOCAL_SV -> $REMOTE_SV（选 15 更新）" >> "$HINT"
    fi

    printf '%s\n' "$NOW" > "$LAST"

    cat "$HINT" 2>/dev/null
}

update_kernel() {

    echo
    echo "检查最新稳定版 sing-box..."

    JSON="$(curl -fsSL --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20" 2>/dev/null)"

    V="$(printf '%s' "$JSON" | jq -r '[.[] | select(.prerelease == false)][0].tag_name' 2>/dev/null | tr -d 'v')"

    [ -n "$V" ] || {
        echo "获取最新版本失败。"
        return
    }

    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64) SB_ARCH="amd64" ;;
        aarch64|arm64) SB_ARCH="arm64" ;;
        armv7l|armv7) SB_ARCH="armv7" ;;
        *) echo "不支持的架构：$ARCH"; return ;;
    esac

    if command -v apk >/dev/null 2>&1; then
        LIBC="musl"
    else
        LIBC="glibc"
    fi

    if [ "$SB_ARCH" = "armv7" ]; then
        FILE="sing-box-${V}-linux-armv7.tar.gz"
    else
        FILE="sing-box-${V}-linux-${SB_ARCH}-${LIBC}.tar.gz"
    fi

    URL="https://github.com/SagerNet/sing-box/releases/download/v${V}/${FILE}"

    echo "[+] $URL"

    TMP="$(work_dir singbox-update)"

    OK=""
    TRY=0

    while [ -z "$OK" ] && [ "$TRY" -lt 3 ]; do
        TRY=$((TRY+1))

        rm -rf "$TMP"
        mkdir -p "$TMP"

        if wget -q --show-progress $(rate_opt) "$URL" -O- | tar -xzf - -C "$TMP"; then
            OK=1
        else
            echo "下载或解压失败，重试 $TRY/3 ..."
            sleep 3
        fi
    done

    [ -n "$OK" ] || {
        echo "下载或解压失败。"
        rm -rf "$TMP"
        return
    }

    SB="$(find "$TMP" -type f -name sing-box | head -n 1)"

    [ -n "$SB" ] || {
        echo "解压失败。"
        rm -rf "$TMP"
        return
    }

    service_stop 2>/dev/null || true

    mv "$SB" "$BIN"
    chown 0:0 "$BIN" 2>/dev/null || true
    chmod 755 "$BIN"

    rm -rf "$TMP"

    rebuild

    service_restart

    rm -f "$BASE/update-hint" "$BASE/.last-update-check"

    printf '%s\n' "$V" > "$BASE/sing-box-version"

    echo
    echo "sing-box 已更新到 $V"
}

update_menu() {

    echo
    echo "=========================================="
    echo " 更新"
    echo "=========================================="

    check_updates

    echo
    echo "1. 更新脚本"
    echo "2. 更新 sing-box 内核"
    echo "0. 返回"
    echo
    printf "请选择："
    read U

    case "$U" in
        1)
            echo "下载最新脚本..."
            curl -fsSL --max-time 20 -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/loser641/singbox-deploy/contents/sb.sh" -o /usr/local/bin/install-singbox.sh || {
                echo "下载失败。"
                return
            }
            chmod +x /usr/local/bin/install-singbox.sh
            sh /usr/local/bin/install-singbox.sh --update-components
            echo "脚本已更新。"
            ;;
        2)
            update_kernel
            ;;
    esac
}

while :; do

    echo

    echo "================================================"
    echo "             sing-box 管理面板"
    echo "================================================"

    echo

    VER="$(cat "$BASE/sing-box-version" 2>/dev/null)"
    if [ -n "$VER" ]; then
        echo "sing-box version $VER"
    else
        "$BIN" version 2>/dev/null | head -n 1
    fi

    echo

    list_configs

    echo
    echo "1. 添加配置"
    echo "2. 更改配置"
    echo "3. 查看配置"
    echo "4. 删除配置"
    echo "5. 分享链接"
    echo "6. 启动"
    echo "7. 停止"
    echo "8. 重启"
    echo "9. 服务状态"
    echo "10. DNS"
    echo "11. BBR"
    echo "12. 申请真实证书（acme.sh）"
    echo "13. 校验配置"
    echo "14. 查看日志"
    echo "15. 更新"
    echo "16. 卸载"
    echo "17. 退出"

    echo
    printf "请选择："
    read MENU

    case "$MENU" in

        1)
            if [ ! -x /usr/local/bin/install-singbox.sh ] || ! grep -q -- '--add-config' /usr/local/bin/install-singbox.sh; then
                echo "下载安装脚本..."
                curl -fsSL --max-time 20 -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/loser641/singbox-deploy/contents/sb.sh" -o /usr/local/bin/install-singbox.sh || {
                    echo "下载失败，请检查网络。"
                    pause
                    continue
                }
                chmod +x /usr/local/bin/install-singbox.sh
            fi
            sh /usr/local/bin/install-singbox.sh --add-config
            pause
            ;;

        2)
            edit_config
            pause
            ;;

        3)
            view_config
            pause
            ;;

        4)
            delete_config
            pause
            ;;

        5)
            show_links
            pause
            ;;

        6)
            service_start
            pause
            ;;

        7)
            service_stop
            pause
            ;;

        8)
            service_restart
            pause
            ;;

        9)
            service_status
            pause
            ;;

        10)
            echo "DNS 配置文件：$BASE/dns.json"
            cat "$BASE/dns.json" 2>/dev/null
            echo
            echo "默认：1.1.1.1"
            printf "输入新 DNS（可逗号分隔），留空取消："
            read DNS_INPUT

            if [ -n "$DNS_INPUT" ]; then

                DNS1="$(printf '%s' "$DNS_INPUT" | cut -d',' -f1)"
                DNS2="$(printf '%s' "$DNS_INPUT" | awk -F',' 'NF > 1 { print $2 }')"

                if [ -n "$DNS2" ]; then

                    cat > "$BASE/dns.json" <<DNSEOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-1",
        "server": "$DNS1"
      },
      {
        "type": "udp",
        "tag": "dns-2",
        "server": "$DNS2"
      }
    ],
    "final": "dns-1"
  }
}
DNSEOF

                else

                    cat > "$BASE/dns.json" <<DNSEOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-1",
        "server": "$DNS1"
      }
    ],
    "final": "dns-1"
  }
}
DNSEOF

                fi

                if rebuild && service_restart; then
                    echo "DNS 已更新：$DNS_INPUT"
                else
                    echo "DNS 更新失败：配置校验未通过，已保留原配置。"
                fi
            fi
            pause
            ;;

        11)
            echo "Current:"
            cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
            echo
            echo "Available:"
            cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
            echo

            if ask_yes_no "启用 BBR"; then
                enable_bbr
            else
                echo "未修改。"
            fi

            pause
            ;;

        12)
            echo "下载证书申请脚本..."
            CERT_TOOL="/tmp/sb-cert.sh"
            if curl -fsSL --max-time 20 -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/loser641/singbox-deploy/contents/cert.sh" -o "$CERT_TOOL"; then
                sh "$CERT_TOOL"
                rm -f "$CERT_TOOL"
            else
                echo "下载失败，请检查网络。"
            fi
            pause
            ;;

        13)
            "$BIN" check -c "$BASE/config.json"
            pause
            ;;

        14)
            if command -v journalctl >/dev/null 2>&1; then
                journalctl -u sing-box --no-pager -n 100
            fi
            pause
            ;;

        15)
            update_menu
            pause
            ;;

        16)
            echo
            if ask_yes_no "确认卸载？"; then
                service_stop 2>/dev/null || true
                rm -f /usr/local/bin/sing-box
                rm -f /usr/local/bin/lsb
                rm -f /usr/local/bin/singbox
                rm -f /usr/local/bin/sing-box-edit-config
                rm -f /usr/local/bin/sing-box-manager
                rm -rf "$BASE"

                if command -v systemctl >/dev/null 2>&1; then
                    systemctl disable sing-box 2>/dev/null || true
                    rm -f /etc/systemd/system/sing-box.service
                    systemctl daemon-reload
                else
                    rm -f /etc/init.d/sing-box
                    crontab -l 2>/dev/null | grep -v '@reboot.*sing-box run' | crontab - 2>/dev/null || true
                fi

                exit 0
            fi
            ;;

        17)
            exit 0
            ;;

    esac
done
EOF

    chmod 755 /usr/local/bin/sing-box-manager

    printf '%s\n' "$SCRIPT_VERSION" > "$BASE/script-version"
}

# ==========================================================
# Generate links helper
# ==========================================================

install_link_generator() {

    cat > "$BASE/generate-links.sh" <<'EOF'
#!/bin/sh

BASE="/etc/sing-box"
LINK_DIR="$BASE/links"
INFO="$BASE/server-info"

mkdir -p "$LINK_DIR"

IP="$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)"

COUNTRY="US"

if [ -f "$INFO" ]; then
    COUNTRY="$(sed -n 's/^COUNTRY=//p' "$INFO")"
fi

rm -f "$LINK_DIR"/*.txt

for FILE in "$BASE/inbounds"/*.json; do

    [ -f "$FILE" ] || continue

    TYPE="$(jq -r '.type' "$FILE")"
    TAG="$(jq -r '.tag' "$FILE")"
    PORT="$(jq -r '.listen_port' "$FILE")"

    case "$TAG" in
        vless-reality) NAME="reality" ;;
        vless-reality-free|vless-reality-免流) NAME="reality免流" ;;
        shadowsocks) NAME="shadowsocks" ;;
        tuic) NAME="tuic" ;;
        anytls) NAME="anytls" ;;
        hysteria2) NAME="hysteria2" ;;
        anyreality) NAME="anyreality" ;;
        *) NAME="$TAG" ;;
    esac

    REMARK="${COUNTRY}-${NAME}"

    case "$TYPE" in

    vless)

        UUID="$(jq -r '.users[0].uuid' "$FILE")"

        if jq -e '.tls.reality.enabled == true' "$FILE" >/dev/null 2>&1; then

            SNI="$(jq -r '.tls.server_name' "$FILE")"
            SID="$(jq -r '.tls.reality.short_id[0]' "$FILE")"

            INFO="$BASE/info/$TAG"

            PBK=""

            if [ -f "$INFO" ]; then
                PBK="$(sed -n 's/^PUBLIC_KEY=//p' "$INFO")"
            fi

            printf '%s\n' \
                "vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp&headerType=none#${REMARK}" \
                > "$LINK_DIR/$TAG.txt"
        fi
        ;;

    shadowsocks)

        METHOD="$(jq -r '.method' "$FILE")"
        PASSWORD="$(jq -r '.password' "$FILE")"

        PASSWORD_ENC="$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"

        printf '%s\n' \
            "ss://${METHOD}:${PASSWORD_ENC}@${IP}:${PORT}#${REMARK}" \
            > "$LINK_DIR/$TAG.txt"
        ;;

    anytls)

        PASSWORD="$(jq -r '.users[0].password' "$FILE")"

        if jq -e '.tls.reality.enabled == true' "$FILE" >/dev/null 2>&1; then

            SNI="$(jq -r '.tls.server_name' "$FILE")"
            SID="$(jq -r '.tls.reality.short_id | if type == "array" then .[0] else . end' "$FILE")"

            INFO="$BASE/info/$TAG"
            PBK=""

            if [ -f "$INFO" ]; then
                PBK="$(sed -n 's/^PUBLIC_KEY=//p' "$INFO")"
            fi

            {
                echo "protocol=anytls"
                echo "server=$IP"
                echo "port=$PORT"
                echo "password=$PASSWORD"
                echo "tls=enabled"
                echo "sni=$SNI"
                echo "security=reality"
                echo "pbk=$PBK"
                echo "sid=$SID"
                echo "fp=chrome"
                echo "remark=$REMARK"
            } > "$LINK_DIR/$TAG.txt"

        else

            {
                echo "protocol=anytls"
                echo "server=$IP"
                echo "port=$PORT"
                echo "password=$PASSWORD"
                echo "sni=www.bing.com"
                echo "allow_insecure=true"
                echo "remark=$REMARK"
            } > "$LINK_DIR/$TAG.txt"

        fi
        ;;

    hysteria2)

        PASSWORD="$(jq -r '.users[0].password' "$FILE")"

        PASSWORD_ENC="$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"

        printf '%s\n' \
            "hysteria2://${PASSWORD_ENC}@${IP}:${PORT}/?sni=www.bing.com&insecure=1#${REMARK}" \
            > "$LINK_DIR/$TAG.txt"
        ;;

    tuic)

        UUID="$(jq -r '.users[0].uuid' "$FILE")"
        PASSWORD="$(jq -r '.users[0].password' "$FILE")"

        PASSWORD_ENC="$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"

        printf '%s\n' \
            "tuic://${UUID}:${PASSWORD_ENC}@${IP}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&allow_insecure=1#${REMARK}" \
            > "$LINK_DIR/$TAG.txt"
        ;;

    esac
done
EOF

    chmod 755 "$BASE/generate-links.sh"
}

# ==========================================================
# Auto detect exit country
# ==========================================================

detect_country() {

    COUNTRY=""

    echo
    echo "=========================================="
    echo " 出口国家检测"
    echo "=========================================="
    echo

    COUNTRY="$(
        curl -4 -fsSL --max-time 5 https://ipinfo.io/json 2>/dev/null |
        jq -r '.country // empty' 2>/dev/null
    )"

    if [ -z "$COUNTRY" ]; then

        COUNTRY="$(
            curl -4 -fsSL --max-time 5 https://ipwho.is/ 2>/dev/null |
            jq -r '.country_code // empty' 2>/dev/null
        )"
    fi

    if [ -z "$COUNTRY" ]; then

        COUNTRY="$(
            curl -4 -fsSL --max-time 5 https://ifconfig.co/json 2>/dev/null |
            jq -r '.country_iso_code // empty' 2>/dev/null
        )"
    fi

    if [ -z "$COUNTRY" ]; then

        COUNTRY="$(
            curl -4 -fsSL --max-time 5 https://api.country.is/ 2>/dev/null
        )"
    fi

    COUNTRY="$(printf '%s' "$COUNTRY" | tr -cd 'A-Za-z' | tr 'a-z' 'A-Z')"

    if [ -z "$COUNTRY" ]; then

        echo "[!] 自动识别失败，请手动输入出口国家简称。"
        printf "出口国家简称 [US]: "
        read COUNTRY_INPUT

        [ -n "$COUNTRY_INPUT" ] && COUNTRY="$COUNTRY_INPUT"

        COUNTRY="$(printf '%s' "$COUNTRY" | tr 'a-z' 'A-Z')"
    fi

    [ -n "$COUNTRY" ] || COUNTRY="US"

    echo "出口国家：$COUNTRY"
}

# ==========================================================
# Initial setup
# ==========================================================

initial_setup() {

    mkdir -p \
        "$INBOUND_DIR" \
        "$LINK_DIR" \
        "$CERT_DIR" \
        "$BASE/info"

    detect_os
    install_dependencies
    install_singbox
    enable_bbr

    install_service
    install_link_generator
    install_lsb

    echo
    echo "=========================================="
    echo " 节点备注设置"
    echo "=========================================="
    echo
    echo "备注格式：出口国家简称-协议名，如 DE-reality、US-reality免流、SG-anyreality"
    echo

    detect_country

    printf 'COUNTRY=%s\n' "$COUNTRY" > "$INFO"
    echo "节点备注国家：$COUNTRY"

    echo
    echo "=========================================="
    echo " 初始配置"
    echo "=========================================="

    echo
    echo "1. VLESS + REALITY"
    echo "2. Shadowsocks"
    echo "3. TUIC"
    echo "4. AnyTLS"
    echo "5. Hysteria2"
    echo "6. AnyReality（AnyTLS + REALITY）"
    echo "7. VLESS + REALITY（免流）"
    echo "8. 全部添加"
    echo

    printf "选择（可多选，如 1,4,6，直接回车跳过）："
    read INIT

    if [ -n "$INIT" ]; then

        run_selection "$INIT"

        rebuild_config || exit 1

        start_service

        "$BASE/generate-links.sh"

    else

        echo
        echo "暂不添加配置，之后可用 lsb 或 singbox 管理面板添加。"
        echo
    fi

    echo
    echo "=========================================="
    echo " 安装完成"
    echo "=========================================="

    echo
    echo "节点信息（客户端导入）："
    echo

    for FILE in "$LINK_DIR"/*.txt; do

        [ -f "$FILE" ] || continue

        echo "----- $(basename "$FILE") -----"
        cat "$FILE"
        echo
    done

    if [ -f "$CERT_DIR/www.bing.com.crt" ]; then
        echo "===== TLS 固定证书（可选，替代跳过证书验证）====="
        echo "v2rayN：节点设置 → 固定证书 → 粘贴下方 PEM（自动禁用跳过验证）"
        echo
        cat "$CERT_DIR/www.bing.com.crt"
        echo
    fi

    echo "管理面板："
    echo
    echo "    lsb  或  singbox"
    echo

    echo "配置目录："
    echo
    echo "    $BASE"
    echo

    if [ -f "$CERT_DIR/www.bing.com.crt" ] && [ -f "$CERT_DIR/www.bing.com.key" ]; then

        echo "证书："
        echo
        echo "    $CERT_DIR/www.bing.com.crt"
        echo

        echo "私钥："
        echo
        echo "    $CERT_DIR/www.bing.com.key"
        echo
    fi
}

# ==========================================================
# Main
# ==========================================================

main() {

    if [ "${1:-}" = "--update-components" ]; then
        install_link_generator
        install_lsb
        printf '%s\n' "$SCRIPT_VERSION" > "$BASE/script-version"
        rm -f "$BASE/update-hint" "$BASE/.last-update-check"
        echo "组件已更新。"
        exit 0
    fi

    if [ "${1:-}" = "--add-config" ]; then
        detect_os
        add_config_menu
        show_links
        exit $?
    fi

    clear 2>/dev/null || true

    if [ -x "$BIN" ] && { [ -x /usr/local/bin/lsb ] || [ -x /usr/local/bin/singbox ]; }; then

        echo "检测到已经安装 sing-box。"
        echo
        echo "直接进入管理面板..."
        sleep 1

        /usr/local/bin/lsb
        exit $?
    fi

    initial_setup
}

main "$@"
