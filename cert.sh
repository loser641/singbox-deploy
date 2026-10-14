#!/bin/sh
# ==========================================================
# sing-box 证书工具（acme.sh）—— 申请 / 恢复自签 / 卸载
#
# 独立于主脚本：只在运行时下载 acme.sh，不预装。
# 申请到的真实证书装入 /etc/sing-box/cert/www.bing.com.crt/.key
# （文件名固定）：主脚本部署协议时看到已有证书会直接复用，
# 不会用自签名覆盖。
# 覆盖安装前自动把现有证书备份到 /root/sb-cert-backup，
# 选"恢复自签名"时原样还原（固定证书 PEM 继续有效），
# 并清除 acme 申请记录，防止自动续期把真证书换回来。
#
# 用法：
#   交互：sh cert.sh
#   申请：sh cert.sh -d 域名 -m dns_cf|standalone|webroot
#            [-w 网站目录] [-e 邮箱] [--staging] [-y]
#   还原：sh cert.sh --restore [-y]
#   卸载：sh cert.sh --uninstall-acme [-y]
# ==========================================================

BASE="/etc/sing-box"
CERT_DIR="$BASE/cert"
CRT="$CERT_DIR/www.bing.com.crt"
KEY="$CERT_DIR/www.bing.com.key"
BACKUP_DIR="/root/sb-cert-backup"
ACME="$HOME/.acme.sh/acme.sh"

DOMAIN=""
METHOD=""
WEBROOT=""
EMAIL=""
STAGING=""
YES=""
ACTION="issue"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)  DOMAIN="$2"; shift 2 ;;
        -m|--method)  METHOD="$2"; shift 2 ;;
        -w|--webroot) WEBROOT="$2"; shift 2 ;;
        -e|--email)   EMAIL="$2"; shift 2 ;;
        --staging)    STAGING=1; shift ;;
        -y|--yes)     YES=1; shift ;;
        --restore)        ACTION="restore"; shift ;;
        --uninstall-acme) ACTION="uninstall"; shift ;;
        -h|--help)
            echo "用法：sh cert.sh -d 域名 -m dns_cf|standalone|webroot [-w 网站目录] [-e 邮箱] [--staging] [-y]"
            echo "     sh cert.sh --restore [-y]         恢复自签名证书（还原备份、防续期换回）"
            echo "     sh cert.sh --uninstall-acme [-y]  卸载 acme.sh"
            exit 0 ;;
        *)
            echo "未知参数：$1（--help 看用法）"
            exit 1 ;;
    esac
done

command_exists() { command -v "$1" >/dev/null 2>&1; }

restart_singbox() {
    if command_exists systemctl; then
        systemctl restart sing-box >/dev/null 2>&1 || true
    else
        pkill -f ^/usr/local/bin/sing-box 2>/dev/null
        sleep 1
        GOMEMLIMIT=24MiB /usr/local/bin/sing-box run -c "$BASE/config.json" >/dev/null 2>&1 &
        sleep 2
        PID="$(pgrep -f '^/usr/local/bin/sing-box' | head -1)"
        if [ -n "$PID" ]; then
            echo 800 > /proc/$PID/oom_score_adj 2>/dev/null
        fi
    fi
}

install_pkgs() {
    MISSING=""
    for p in "$@"; do
        command_exists "$p" || MISSING="$MISSING $p"
    done
    [ -n "$MISSING" ] || return 0
    echo "安装依赖：$MISSING"
    if [ -f /etc/alpine-release ]; then
        # 64MB 小内存：先停 sing-box 腾出内存，避免 apk 被 OOM 杀掉（装完立即拉起）
        WAS_RUNNING=""
        if pgrep -f '^/usr/local/bin/sing-box' >/dev/null 2>&1; then
            WAS_RUNNING=1
            pkill -f '^/usr/local/bin/sing-box' 2>/dev/null
            sleep 1
        fi
        APK_OK=""
        for i in 1 2 3; do
            if apk add --no-cache $MISSING >/dev/null 2>&1; then
                APK_OK=1
                break
            fi
            sleep 2
        done
        if [ -n "$WAS_RUNNING" ]; then
            GOMEMLIMIT=24MiB /usr/local/bin/sing-box run -c "$BASE/config.json" >/dev/null 2>&1 &
            sleep 2
            PID="$(pgrep -f '^/usr/local/bin/sing-box' | head -1)"
            if [ -n "$PID" ]; then
                echo 800 > /proc/$PID/oom_score_adj 2>/dev/null
            fi
        fi
        [ -n "$APK_OK" ] || { echo "依赖安装失败：$MISSING"; return 1; }
    elif command_exists apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING >/dev/null 2>&1 || { echo "依赖安装失败：$MISSING"; return 1; }
    else
        echo "不支持的系统，请手动安装：$MISSING"
        return 1
    fi
}

gen_selfsigned() {
    install_pkgs openssl || return 1
    mkdir -p "$CERT_DIR"
    cat > "$CERT_DIR/openssl.cnf" <<CNFEOF
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
CNFEOF
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
    if [ ! -s "$KEY" ] || [ ! -s "$CRT" ]; then
        echo "自签名证书生成失败。"
        return 1
    fi
    chmod 600 "$KEY"
    chmod 644 "$CRT"
}

backup_cert() {
    if [ ! -d "$BACKUP_DIR" ] && [ -s "$CRT" ] && [ -s "$KEY" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -f "$CRT" "$BACKUP_DIR/www.bing.com.crt"
        cp -f "$KEY" "$BACKUP_DIR/www.bing.com.key"
        echo "已备份现有证书到 $BACKUP_DIR"
    fi
}

restore_selfsigned() {
    echo
    echo "=========================================="
    echo " 恢复自签名证书"
    echo "=========================================="
    # 清除 acme 申请记录，防止自动续期把真实证书换回来
    if [ -x "$ACME" ]; then
        for d in "$HOME"/.acme.sh/*; do
            [ -d "$d" ] || continue
            base="$(basename "$d")"
            case "$base" in
                *.*) "$ACME" --remove -d "${base%_ecc}" >/dev/null 2>&1; rm -rf "$d" ;;
            esac
        done
    fi
    rm -f /tmp/.sb-cert-new.crt /tmp/.sb-cert-new.key

    if [ -s "$BACKUP_DIR/www.bing.com.crt" ] && [ -s "$BACKUP_DIR/www.bing.com.key" ]; then
        mkdir -p "$CERT_DIR"
        cp -f "$BACKUP_DIR/www.bing.com.crt" "$CRT"
        cp -f "$BACKUP_DIR/www.bing.com.key" "$KEY"
        chmod 600 "$KEY"
        chmod 644 "$CRT"
        echo "已还原备份证书（原固定证书 PEM 继续有效）。"
    else
        echo "没有备份证书，生成新的自签名证书（客户端需重新固定 PEM）。"
        gen_selfsigned || exit 1
    fi

    restart_singbox
    echo "完成。REALITY 类节点不使用此证书，不受影响。"
}

uninstall_acme() {
    echo
    echo "=========================================="
    echo " 卸载 acme.sh"
    echo "=========================================="
    if [ -s "$CRT" ] && command_exists openssl; then
        ISSUER="$(openssl x509 -in "$CRT" -noout -issuer 2>/dev/null)"
        case "$ISSUER" in
            *bing*) ;;
            *)
                echo "[!] 当前安装的是真实证书：$ISSUER"
                echo "    卸载后将不再自动续期，到期后客户端校验会失败。"
                echo "    如需稳妥，先恢复自签名证书再卸载。"
                if [ -z "$YES" ]; then
                    printf "仍要卸载 acme.sh？[y/N]："
                    read ANS
                    case "$ANS" in
                        y|Y|yes|YES) ;;
                        *) echo "已取消。"; return 0 ;;
                    esac
                fi
                ;;
        esac
    fi
    crontab -l 2>/dev/null | grep -v acme | crontab - 2>/dev/null || true
    rm -rf "$HOME/.acme.sh"
    rm -f /tmp/.sb-cert-new.crt /tmp/.sb-cert-new.key
    echo "acme.sh 已卸载（证书文件未改动）。"
}

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
    if [ -s "$BACKUP_DIR/www.bing.com.crt" ]; then
        echo "备份证书：$BACKUP_DIR（可还原）"
    else
        echo "备份证书：无"
    fi
}

echo "=========================================="
echo " sing-box 证书工具（acme.sh）"
echo "=========================================="
show_cert_status
echo

if [ "$ACTION" = "restore" ]; then
    restore_selfsigned
    exit $?
fi

if [ "$ACTION" = "uninstall" ]; then
    uninstall_acme
    exit $?
fi

if [ -z "$METHOD" ]; then
    echo "1. 申请真实证书"
    echo "2. 恢复自签名证书（还原备份，防止自动续期换回）"
    echo "3. 卸载 acme.sh（清除申请记录与自动续期）"
    echo "0. 退出"
    printf "请选择："
    read ANS
    case "$ANS" in
        1) ;;
        2) restore_selfsigned; exit $? ;;
        3) uninstall_acme; exit $? ;;
        *) echo "已取消。"; exit 0 ;;
    esac

    echo
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

install_pkgs bash openssl curl || exit 1
if [ "$METHOD" = "standalone" ]; then
    install_pkgs socat || exit 1
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

MARK="/tmp/.sb-cert-issue-marker"
touch "$MARK"
sleep 1

if [ -n "$STAGING" ]; then
    CA_OPT="--staging"
else
    CA_OPT="--server letsencrypt"
fi

case "$METHOD" in
    dns_cf)
        "$ACME" --issue --force -d "$DOMAIN" --dns dns_cf $CA_OPT
        ;;
    standalone)
        "$ACME" --issue --force -d "$DOMAIN" --standalone $CA_OPT
        ;;
    webroot)
        "$ACME" --issue --force -d "$DOMAIN" -w "$WEBROOT" $CA_OPT
        ;;
esac

ISSUE_OK=""
for d in "$HOME/.acme.sh/${DOMAIN}_ecc" "$HOME/.acme.sh/$DOMAIN"; do
    if [ -s "$d/fullchain.cer" ] && [ "$d/fullchain.cer" -nt "$MARK" ]; then
        ISSUE_OK=1
    fi
done
rm -f "$MARK"

if [ -z "$ISSUE_OK" ]; then
    echo "签发失败（详见上方 acme 输出），原有证书未改动。"
    exit 1
fi

# ---------- 4. 安装到 /etc/sing-box/cert ----------

echo "[4/4] 安装证书到 $CERT_DIR ..."

backup_cert
mkdir -p "$CERT_DIR"

TMP_CRT="/tmp/.sb-cert-new.crt"
TMP_KEY="/tmp/.sb-cert-new.key"
rm -f "$TMP_CRT" "$TMP_KEY"

if command_exists systemctl; then
    RELOAD="if [ -s $TMP_CRT ] && [ -s $TMP_KEY ]; then mv $TMP_CRT $CRT; mv $TMP_KEY $KEY; chmod 600 $KEY; chmod 644 $CRT; fi; systemctl restart sing-box >/dev/null 2>&1 || true"
else
    RELOAD="if [ -s $TMP_CRT ] && [ -s $TMP_KEY ]; then mv $TMP_CRT $CRT; mv $TMP_KEY $KEY; chmod 600 $KEY; chmod 644 $CRT; fi; pkill -f ^/usr/local/bin/sing-box 2>/dev/null; sleep 1; GOMEMLIMIT=24MiB /usr/local/bin/sing-box run -c $BASE/config.json >/dev/null 2>&1 & sleep 2; P=\$(pgrep -f ^/usr/local/bin/sing-box | head -1); if [ -n \"\$P\" ]; then echo 800 > /proc/\$P/oom_score_adj 2>/dev/null; fi; true"
fi

"$ACME" --install-cert -d "$DOMAIN" --fullchain-file "$TMP_CRT" --key-file "$TMP_KEY" --reloadcmd "$RELOAD" || {
    echo "证书安装失败，原有证书未改动。"
    rm -f "$TMP_CRT" "$TMP_KEY"
    exit 1
}

if [ ! -s "$CRT" ] || [ ! -s "$KEY" ]; then
    echo "证书落盘校验失败，原有证书未改动。"
    rm -f "$TMP_CRT" "$TMP_KEY"
    exit 1
fi

echo
echo "=========================================="
echo " 真实证书已安装"
echo "=========================================="
command_exists openssl && openssl x509 -in "$CRT" -noout -issuer -subject -dates 2>/dev/null
echo
echo "证书：$CRT"
echo "私钥：$KEY"
echo "备份：$BACKUP_DIR（要换回自签，运行本工具选 2）"
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
