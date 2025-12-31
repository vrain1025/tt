#!/bin/bash

# ==============================================================
# Xray VLESS + WebSocket 部署脚本 (Lunes/Pterodactyl 专用)
# 特点：极高稳定性、抗断流、支持 Cloudflare、开机自启
# ==============================================================

export LC_ALL=C
set -u

# --- 1. 变量定义 ---
# Xray 最新正式版
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"
XRAY_BIN="./xray"
CONFIG_FILE="config.json"
PKG_FILE="package.json"
WS_PATH="/ws"  # WebSocket 路径，可自定义

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

# --- 2. 端口处理 ---
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    PORT="$1"
elif [[ -n "${SERVER_PORT:-}" ]]; then
    PORT="$SERVER_PORT"
else
    PORT=$(( (RANDOM % 10000) + 20000 ))
    echo "⚠️  未指定端口，使用随机端口: $PORT"
fi

echo "🚀 [1/5] 准备部署 VLESS + WS (Port: $PORT)..."

# --- 3. 环境清理与依赖检查 ---
pkill -f xray || true
rm -f "$XRAY_BIN" "xray.zip" "geoip.dat" "geosite.dat"

if ! command -v unzip &> /dev/null; then
    echo "📦 安装 unzip..."
    # 尝试安装 unzip，如果没权限则只能祈祷系统自带
    apt-get update && apt-get install -y unzip &>/dev/null || apk add unzip &>/dev/null || true
fi

# --- 4. 下载并安装 Xray ---
echo "📥 [2/5] 下载 Xray Core..."
curl -L -o xray.zip "$XRAY_URL"

echo "📦 [3/5] 解压与安装..."
unzip -q -o xray.zip
chmod +x "$XRAY_BIN"

if [[ ! -f "$XRAY_BIN" ]]; then
    echo "❌ Xray 安装失败，找不到二进制文件。"
    exit 1
fi

# 清理垃圾
rm -f xray.zip *.dat LICENSE README.md

# --- 5. 生成配置文件 (config.json) ---
echo "📝 [4/5] 生成 VLESS 配置文件..."
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# --- 6. 设置开机自启 (package.json) ---
echo "⚙️  [5/5] 配置容器自启动..."
cat > "$PKG_FILE" <<EOF
{
  "name": "xray-vless",
  "version": "1.0.0",
  "description": "Xray VLESS WS",
  "scripts": {
    "start": "chmod +x ./xray && ./xray run -c config.json"
  }
}
EOF

# --- 7. 输出链接 ---
get_ip() {
    curl -s4 https://ifconfig.me || echo "SERVER_IP"
}
SERVER_IP=$(get_ip)

# 生成标准 VLESS 链接
# 格式: vless://UUID@IP:PORT?security=none&encryption=none&type=ws&path=/ws#Name
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=none&encryption=none&type=ws&path=${WS_PATH}#Lunes-VLESS"

echo ""
echo "========================================================"
echo "✅ 部署成功！VLESS + WebSocket 已启动。"
echo "========================================================"
echo "🔗 连接链接 (复制导入 v2rayN):"
echo ""
echo "$LINK"
echo ""
echo "========================================================"
echo "⚠️  客户端设置提示："
echo "1. 这是一个纯 HTTP 协议节点 (security=none)，速度快。"
echo "2. 如果 IP 被墙，可将 IP 改为 Cloudflare 优选 IP (前提是端口支持 CF)。"
echo "========================================================"

# --- 8. 启动 ---
echo "🚀 正在启动服务..."
./xray run -c config.json
