#!/bin/bash
# =========================================
# TUIC v1.4.5 over QUIC 自动部署脚本（修复版）
# =========================================
set -u # 移除 -e，防止中间步骤报错直接退出容器，方便调试
export LC_ALL=C
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"

# ========== 环境检查 ==========
check_dependencies() {
    echo "🔍 Checking dependencies..."
    if ! command -v openssl &> /dev/null; then
        echo "❌ Error: openssl is missing. Please install it (apt-get install openssl or apk add openssl)."
        exit 1
    fi
    if ! command -v curl &> /dev/null; then
        echo "❌ Error: curl is missing."
        exit 1
    fi
}

# ========== 随机端口 ==========
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

# ========== 选择端口 ==========
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ Using specified port: $TUIC_PORT"
    return
  fi

  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ Using environment port: $TUIC_PORT"
    return
  fi

  TUIC_PORT=$(random_port)
  echo "🎲 Random port selected: $TUIC_PORT"
}

# ========== 检查已有配置 ==========
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server' "$SERVER_TOML" | grep -Eo '[0-9]+' | head -n1)
    # 简单提取 UUID 和 密码，如果格式复杂可能失效，建议重新生成
    if grep -q '\[users\]' "$SERVER_TOML"; then
        TUIC_UUID=$(grep -A1 '\[users\]' "$SERVER_TOML" | tail -n1 | awk '{print $1}')
        TUIC_PASSWORD=$(grep -A1 '\[users\]' "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
        echo "📂 Existing config detected (Port: $TUIC_PORT). Loading..."
        return 0
    fi
  fi
  return 1
}

# ========== 生成证书 ==========
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 Certificate exists, skipping."
    return
  fi
  echo "🔐 Generating self-signed certificate for ${MASQ_DOMAIN}..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ========== 下载 tuic-server ==========
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server already exists."
    return
  fi
  echo "📥 Downloading tuic-server..."
  # 尝试下载
  curl -L -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux"
  chmod +x "$TUIC_BIN"
  
  # 简单的二进制兼容性测试
  echo "🧪 Testing binary compatibility..."
  if ! "$TUIC_BIN" --version >/dev/null 2>&1; then
     echo "⚠️ Warning: The binary might not run on this OS (Alpine?). Trying to run anyway but expect errors."
     echo "ℹ️ info: If you are on Alpine, try installing gcompat: apk add gcompat"
  fi
}

# ========== 生成配置 ==========
generate_config() {
# 修复：Restful 端口不能和 Server 端口一致，这里让 Restful 端口 +1 或者固定一个无关端口
local REST_PORT=$((TUIC_PORT + 1))

cat > "$SERVER_TOML" <<EOF
log_level = "info"
server = "0.0.0.0:${TUIC_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${REST_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = $((1200 + RANDOM % 200))
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"

[quic.congestion_control]
controller = "bbr"
initial_window = 6291456
EOF
}

# ========== 获取公网IP ==========
get_server_ip() {
  if [[ -n "${SERVER_IP:-}" ]]; then echo "$SERVER_IP"; return; fi
  if [[ -n "${PTERODACTYL_SERVER_IP:-}" ]]; then echo "$PTERODACTYL_SERVER_IP"; return; fi
  # 尝试探测外网IP
  curl -s4 https://ifconfig.me || echo "127.0.0.1"
}

# ========== 生成TUIC链接 ==========
generate_link() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF
  echo "----------------------------------------------------"
  echo "🔗 TUIC link generated successfully:"
  cat "$LINK_TXT"
  echo "----------------------------------------------------"
}

# ========== 守护进程 ==========
run_background_loop() {
  echo "🚀 Starting TUIC server on port $TUIC_PORT..."
  echo "📝 Logs will be shown below (Press Ctrl+C to stop if testing locally):"
  
  while true; do
    # 核心修改：移除了 >/dev/null，现在你能看到报错了
    "$TUIC_BIN" -c "$SERVER_TOML" || true
    
    echo "⚠️ TUIC stopped or crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主流程 ==========
main() {
  check_dependencies
  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo 'uuid-gen-failed')"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    generate_cert
    check_tuic_server
    generate_config
  else
    generate_cert
    check_tuic_server
  fi

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
