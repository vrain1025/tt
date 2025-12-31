#!/bin/bash
set -u
export LC_ALL=C

# ================= 配置区 =================
# 如果你知道面板给你分配了什么端口，请修改下面这行
# 例如：PORT=10200
# 如果留空，脚本会尝试随机生成（可能会被防火墙拦截）
PORT="" 

PASSWORD=$(openssl rand -hex 16)
HY2_BIN="./hysteria"
CONFIG_YAML="config.yaml"
CERT_PEM="server.crt"
KEY_PEM="server.key"

# ================= 1. 环境检查 =================
echo "🔍 Checking dependencies..."
if ! command -v openssl &> /dev/null; then echo "❌ Missing openssl. Please install it."; exit 1; fi
if ! command -v curl &> /dev/null; then echo "❌ Missing curl. Please install it."; exit 1; fi

# ================= 2. 端口处理 =================
if [[ -z "$PORT" ]]; then
    if [[ -n "${SERVER_PORT:-}" ]]; then
        PORT="$SERVER_PORT"
        echo "✅ Using environment port: $PORT"
    else
        PORT=$(( (RANDOM % 10000) + 20000 ))
        echo "⚠️ No port specified. Using random port: $PORT (Make sure to allow this in firewall!)"
    fi
else
    echo "✅ Using specified port: $PORT"
fi

# ================= 3. 下载 Hysteria 2 =================
if [[ ! -f "$HY2_BIN" ]]; then
    echo "📥 Downloading Hysteria 2..."
    # 自动判断架构，Node容器通常是 x86_64 (amd64)
    curl -L -o "$HY2_BIN" "https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64"
    chmod +x "$HY2_BIN"
fi

# ================= 4. 生成证书 =================
if [[ ! -f "$CERT_PEM" ]]; then
    echo "🔐 Generating self-signed certificate..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=bing.com" -days 3650 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_PEM"
    chmod 644 "$CERT_PEM"
fi

# ================= 5. 生成配置 =================
echo "📝 Generating config..."
cat > "$CONFIG_YAML" <<EOF
listen: :$PORT

tls:
  cert: $CERT_PEM
  key: $KEY_PEM

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true

ignoreClientBandwidth: true
EOF

# ================= 6. 获取 IP 并生成链接 =================
get_ip() {
    curl -s4 https://ifconfig.me || echo "127.0.0.1"
}

IP=$(get_ip)

echo ""
echo "========================================================"
echo "🎉 Hysteria 2 Installed Successfully!"
echo "========================================================"
echo "📋 Connection Link (Copy to v2rayN / Nekoray):"
echo ""
echo "hysteria2://$PASSWORD@$IP:$PORT/?insecure=1&sni=bing.com#Hy2-$IP"
echo ""
echo "========================================================"

# ================= 7. 启动服务 =================
echo "🚀 Starting Server..."
# 循环运行以防崩溃
while true; do
    "$HY2_BIN" server -c "$CONFIG_YAML"
    echo "⚠️ Server stopped. Restarting in 3s..."
    sleep 3
done
