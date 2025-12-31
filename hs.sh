#!/bin/bash

# ==============================================================
# Hysteria 2 终极部署脚本 (Lunes/Pterodactyl 专用)
# 功能：自动开机自启、防断流配置、自动更新、一键输出链接
# ==============================================================

export LC_ALL=C
set -u

# --- 1. 变量定义 ---
# 强制使用 v2.6.5 (稳定，修复断流)
HY_URL="https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.5/hysteria-linux-amd64"
HY_BIN="./hysteria"
CONFIG_FILE="config.yaml"
CERT_FILE="server.crt"
KEY_FILE="server.key"
PKG_FILE="package.json"

# 生成随机强密码 (避免弱密码报错)
UUID=$(openssl rand -hex 16)
# 生成混淆密码 (必须 > 4字符)
OBFS_PASS="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')"

# --- 2. 端口处理 ---
# 优先级：脚本参数 > 环境变量 > 随机
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    PORT="$1"
elif [[ -n "${SERVER_PORT:-}" ]]; then
    PORT="$SERVER_PORT"
else
    PORT=$(( (RANDOM % 10000) + 20000 ))
    echo "⚠️  未指定端口，使用随机端口: $PORT (请确保面板已开放此端口)"
fi

echo "🚀 [1/6] 准备部署 Hysteria 2 (端口: $PORT)..."

# --- 3. 环境清理与下载 ---
# 杀掉可能正在运行的旧进程，防止文件占用
pkill -f hysteria || true

# 下载核心
if [[ ! -f "$HY_BIN" ]]; then
    echo "📥 [2/6] 下载核心组件 (v2.6.5)..."
    curl -L -o "$HY_BIN" "$HY_URL"
    chmod +x "$HY_BIN"
else
    echo "♻️  [2/6] 核心已存在，跳过下载 (如需更新请先手动删除 hysteria 文件)"
    chmod +x "$HY_BIN"
fi

# --- 4. 生成证书 ---
if [[ ! -f "$CERT_FILE" ]]; then
    echo "🔐 [3/6] 生成自签名证书..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=www.bing.com" -days 3650 -nodes >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
fi

# --- 5. 生成配置文件 (关键：防断流调优) ---
echo "📝 [4/6] 写入防断流配置..."
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
    url: https://www.cloudflare.com/
    rewriteHost: true

# 必须为 false，否则容器网络会爆炸
ignoreClientBandwidth: false

# 【核心修复】针对 Lunes 容器的极致优化参数
quic:
  # 30秒无数据自动断开，释放资源
  maxIdleTimeout: 30s
  # 【重点】每 3秒 发送一次心跳，强制维持 NAT 映射，防止 Timeout
  keepAlivePeriod: 3s
  # 【重点】关闭 MTU 探测，防止大包发不出导致断流
  disablePathMTUDiscovery: true
EOF

# --- 6. 修复“无法重启” (写入 package.json) ---
# 这是让面板 Restart 按钮生效的关键
echo "⚙️  [5/6] 配置容器自启动 (package.json)..."
cat > "$PKG_FILE" <<EOF
{
  "name": "hysteria-server",
  "version": "1.0.0",
  "description": "Auto start hysteria",
  "scripts": {
    "start": "chmod +x ./hysteria && ./hysteria server -c config.yaml"
  }
}
EOF

# --- 7. 输出信息与启动 ---
get_ip() {
    curl -s4 https://ifconfig.me || echo "你的服务器IP"
}
SERVER_IP=$(get_ip)

echo ""
echo "========================================================"
echo "✅ 部署成功！自启动已配置。"
echo "========================================================"
echo "🔗 复制以下链接到 v2rayN / Nekoray / Clash:"
echo ""
echo "hysteria2://$UUID@$SERVER_IP:$PORT/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=$OBFS_PASS#Lunes-H2"
echo ""
echo "========================================================"
echo "⚠️  【必读】防断流客户端设置指南："
echo "1. 必须开启 '允许不安全连接' (AllowInsecure: true)"
echo "2. 上传速度限制 (Upload): 设置为 8 Mbps (超过容易断)"
echo "3. 下载速度限制 (Download): 设置为 20-30 Mbps"
echo "========================================================"

echo "🚀 [6/6] 正在启动服务..."
# 直接启动一次，确保用户立刻能用
# 使用 exec 会替换当前 shell，但为了保证脚本跑完，我们直接跑
./hysteria server -c config.yaml
