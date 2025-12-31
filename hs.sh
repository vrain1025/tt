#!/bin/bash

# ==============================================================
# Hysteria 2 一键部署脚本 (Lunes/Pterodactyl 专用版)
# 功能：自动安装/更新、配置防断流、设置开机自启、输出节点链接
# ==============================================================

export LC_ALL=C
set -u

# --- 1. 变量定义 ---
# 强制使用 v2.6.5 稳定版，修复已知断流问题
HY_URL="https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.5/hysteria-linux-amd64"
HY_BIN="./hysteria"
CONFIG_FILE="config.yaml"
CERT_FILE="server.crt"
KEY_FILE="server.key"
PKG_FILE="package.json"

# 生成随机强密码
UUID=$(openssl rand -hex 16)
# 生成强混淆密码 (必须 > 4字符)
OBFS_PASS="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')"

# --- 2. 端口处理 ---
# 优先级：脚本参数($1) > 环境变量($SERVER_PORT) > 随机端口
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    PORT="$1"
elif [[ -n "${SERVER_PORT:-}" ]]; then
    PORT="$SERVER_PORT"
else
    PORT=$(( (RANDOM % 10000) + 20000 ))
    echo "⚠️ 未指定端口，使用随机端口: $PORT"
fi

echo "🚀 开始部署 Hysteria 2 (Port: $PORT)..."

# --- 3. 环境检查与清理 ---
if ! command -v openssl &> /dev/null; then echo "❌ 缺少 openssl，请先安装"; exit 1; fi
if ! command -v curl &> /dev/null; then echo "❌ 缺少 curl，请先安装"; exit 1; fi

# 清理旧核心，确保更新生效
if [[ -f "$HY_BIN" ]]; then
    echo "♻️ 检测到旧版本，正在删除并更新..."
    rm -f "$HY_BIN"
fi

# --- 4. 下载核心 ---
echo "📥 正在下载 Hysteria v2.6.5..."
curl -L -o "$HY_BIN" "$HY_URL"
chmod +x "$HY_BIN"

if [[ ! -f "$HY_BIN" ]]; then
    echo "❌ 下载失败，请检查网络或 GitHub 连接。"
    exit 1
fi

# --- 5. 生成证书 ---
if [[ ! -f "$CERT_FILE" ]]; then
    echo "🔐 生成自签名证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=bing.com" -days 3650 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
fi

# --- 6. 生成配置文件 (关键防断流优化) ---
echo "📝 生成最佳配置文件..."
cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $UUID

obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

# 必须开启流控，配合客户端限制带宽
ignoreClientBandwidth: false

# 核心优化：解决容器网络 UDP 断流和超时
quic:
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: true
EOF

# --- 7. 设置开机自启 (通过劫持 npm start) ---
echo "⚙️ 设置开机自启 (修改 package.json)..."
cat > "$PKG_FILE" <<EOF
{
  "name": "hysteria-runner",
  "version": "1.0.0",
  "description": "Auto start hysteria",
  "scripts": {
    "start": "chmod +x ./hysteria && ./hysteria server -c config.yaml"
  }
}
EOF

# --- 8. 获取 IP 并输出链接 ---
get_ip() {
    curl -s4 https://ifconfig.me || echo "127.0.0.1"
}
SERVER_IP=$(get_ip)

echo ""
echo "========================================================"
echo "✅ 部署完成！Server is ready."
echo "========================================================"
echo "📋 请将以下链接导入 v2rayN / Nekoray / Clash Verge:"
echo ""
echo "hysteria2://$UUID@$SERVER_IP:$PORT/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=$OBFS_PASS#Lunes-H2"
echo ""
echo "========================================================"
echo "⚠️  客户端设置重要提示 (必看)："
echo "1. 允许不安全连接 (AllowInsecure): 开启"
echo "2. 上传速度限制 (Upload Bandwidth): 建议设置 10 Mbps"
echo "3. 下载速度限制 (Download Bandwidth): 建议设置 30 Mbps"
echo "========================================================"

# --- 9. 尝试立即启动 ---
echo "🚀 正在启动服务..."
# 这里不使用 exec，因为如果是 curl | bash 运行，exec 会导致 shell 退出
"$HY_BIN" server -c "$CONFIG_FILE"
