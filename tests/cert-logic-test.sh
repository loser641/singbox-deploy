#!/bin/sh
# 本地测试 sb.sh 的证书域名校验 / base64url / 文件命名逻辑
# 用法：sh tests/cert-logic-test.sh <repo/sb.sh>

SRC="${1:-repo/sb.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 只截取需要的函数体，避免跑整个脚本。
# 注意：cert_file_base / cert_apply_name 在嵌入的面板脚本里还会再出现一次，
# 所以只取「第一次出现」的那一段。
awk '
    /^cert_file_base\(\)/ { inrange = 1 }
    /^load_cert_source\(\)/ { exit }
    inrange { print }
' "$SRC" > "$TMP/funcs.sh"

# 再单独追加 load_cert_source 函数本体（按花括号配平截取）
awk '
    /^load_cert_source\(\)/ { infn = 1; depth = 0 }
    infn {
        print
        n = gsub(/\{/, "{")
        m = gsub(/\}/, "}")
        depth += n - m
        if (depth == 0 && seen) exit
        if (n > 0) seen = 1
    }
' "$SRC" >> "$TMP/funcs.sh"

BASE="$TMP/base"
CERT_DIR="$BASE/cert"
CERT_DEFAULT_SNI="www.bing.com"
CERT_SNI="$CERT_DEFAULT_SNI"
CERT_CRT=""
CERT_KEY=""
CERT_INSECURE="1"
CERT_SRC_CONF="$BASE/cert-source.conf"
CERT_NAME_FILE="$BASE/cert-name"
mkdir -p "$CERT_DIR"

. "$TMP/funcs.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $1  ($2)"; }

echo "=== cert_valid_name 应通过 ==="
for d in example.com www.bing.com a.b.c.example.co.uk xn--fiqs8s.xn--fiqz9s \
         my-host.example.com 1.2.3.4 0.0.0.0 255.255.255.255 \
         ::1 2001:db8::1 fe80::1 ::ffff:192.168.1.1; do
    if cert_valid_name "$d"; then ok "$d"; else no "$d" "应通过"; fi
done

echo
echo "=== cert_valid_name 应拒绝 ==="
for d in localhost example .example.com example.com. exa..mple.com \
         -example.com example-.com "exam ple.com" https://example.com \
         example.com/path "example.com?x=1" user@example.com exam_ple.com \
         example.123 example.c 256.1.1.1 1.2.3 01.2.3.4 1.2.3.4.5 \
         ::1::2 2001:db8:::1 gggg::1 example.com:443 ""; do
    if cert_valid_name "$d"; then no "$d" "应拒绝"; else ok "$d"; fi
done

echo
echo "=== base64url ==="
R="$(cert_b64url 'example.com')"
[ "$R" = "ZXhhbXBsZS5jb20" ] && ok "example.com → $R" || no "example.com" "得到 $R"
R="$(cert_b64url '2001:db8::1')"
case "$R" in
    *'='*|*'+'*|*'/'*) no "2001:db8::1" "含 padding 或 +/" ;;
    *) ok "2001:db8::1 → $R" ;;
esac
R="$(cert_b64url '85.189.44.47')"
[ "$R" = "ODUuMTg5LjQ0LjQ3" ] && ok "IPv4 → $R" || no "IPv4" "得到 $R"

echo
echo "=== 文件命名 ==="
CERT_SNI="example.com"; cert_apply_name
[ "$CERT_CRT" = "$CERT_DIR/example.com.crt" ] && ok "域名路径" || no "域名路径" "$CERT_CRT"
CERT_SNI="2001:db8::1"; cert_apply_name
[ "$CERT_CRT" = "$CERT_DIR/2001_db8__1.crt" ] && ok "IPv6 冒号转下划线" || no "IPv6" "$CERT_CRT"

echo
echo "=== cert-name 持久化 ==="
CERT_SNI="pan.example.org"
cert_save_name
CERT_SNI="$CERT_DEFAULT_SNI"
CERT_EXTERNAL="0"
load_cert_source
[ "$CERT_SNI" = "pan.example.org" ] && ok "load_cert_source 读回 cert-name" || no "cert-name" "$CERT_SNI"
[ "$CERT_CRT" = "$CERT_DIR/pan.example.org.crt" ] && ok "路径随域名" || no "路径" "$CERT_CRT"
[ "$CERT_EXTERNAL" = "0" ] && ok "无外部证书 → 非 external" || no "external" "$CERT_EXTERNAL"

echo
echo "=== 外部证书目录优先级 ==="
echo dummy > "$CERT_DIR/ext.crt"
echo dummy > "$CERT_DIR/ext.key"
cat > "$CERT_SRC_CONF" <<EOF
CERT_CRT='$CERT_DIR/ext.crt'
CERT_KEY='$CERT_DIR/ext.key'
CERT_SNI='ext.example.net'
CERT_INSECURE='0'
EOF
load_cert_source
[ "$CERT_EXTERNAL" = "1" ] && ok "识别为 external" || no "external" "$CERT_EXTERNAL"
[ "$CERT_SNI" = "ext.example.net" ] && ok "SNI 来自外部配置" || no "SNI" "$CERT_SNI"

echo
echo "=== 外部证书丢失 → 回退自签 ==="
rm -f "$CERT_DIR/ext.crt"
load_cert_source
[ "$CERT_EXTERNAL" = "0" ] && ok "回退非 external" || no "external" "$CERT_EXTERNAL"
[ "$CERT_SNI" = "www.bing.com" ] && ok "SNI 回退默认" || no "SNI" "$CERT_SNI"

echo
echo "结果：$PASS 通过 / $FAIL 失败"
[ "$FAIL" -eq 0 ]
