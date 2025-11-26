#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

PROXY_STATE_FILE="/home/user/.astrbot-backup/napcat-proxy.json"
PROXYCHAINS_CONF="/home/user/proxychains.conf"
DEFAULT_PROXY="${NAPCAT_PROXY_DEFAULT:-on}"

# Gost local proxy port (used when auth is needed)
GOST_LOCAL_PORT="${GOST_LOCAL_PORT:-11080}"
GOST_BIN="/home/user/gost"
GOST_PID_FILE="/tmp/gost-napcat.pid"

normalize_bool() {
  local v="${1:-}"
  v="${v,,}"
  case "$v" in
    1|true|on|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

should_enable_proxy() {
  local val=""
  if [[ -f "$PROXY_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r 'if has("enabled") then .enabled else "" end' "$PROXY_STATE_FILE" 2>/dev/null || true)
  fi
  if [[ -z "$val" ]]; then
    val="$DEFAULT_PROXY"
  fi
  if normalize_bool "$val"; then return 0; else return 1; fi
}

# Cleanup gost on exit
cleanup_gost() {
  if [[ -f "$GOST_PID_FILE" ]]; then
    kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
    rm -f "$GOST_PID_FILE"
  fi
}
trap cleanup_gost EXIT

# Write proxychains config
write_proxychains_conf() {
  local host="$1"
  local port="$2"
  cat > "$PROXYCHAINS_CONF" <<EOF
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5 ${host} ${port}
EOF
  chmod 644 "$PROXYCHAINS_CONF" || true
}

read -r -a EXTRA_FLAGS <<< "${NAPCAT_FLAGS:-}"

# Determine proxy mode
USE_PROXY=false
PROXY_HOST=""
PROXY_PORT=""

if should_enable_proxy; then
  if [[ -n "${PROXY_SOCKS5_HOST:-}" && -n "${PROXY_SOCKS5_PORT:-}" ]]; then
    USE_PROXY=true
    
    # If authentication is needed, use gost as local forwarder
    if [[ -n "${PROXY_SOCKS5_USER:-}" ]]; then
      echo "[napcat] starting gost forwarder for authenticated proxy..."
      UPSTREAM="socks5://${PROXY_SOCKS5_USER}:${PROXY_SOCKS5_PASS:-}@${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
      "$GOST_BIN" -L "socks5://:${GOST_LOCAL_PORT}" -F "$UPSTREAM" &
      echo $! > "$GOST_PID_FILE"
      sleep 1  # Wait for gost to start
      PROXY_HOST="127.0.0.1"
      PROXY_PORT="$GOST_LOCAL_PORT"
      echo "[napcat] gost forwarding to ${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
    else
      PROXY_HOST="${PROXY_SOCKS5_HOST}"
      PROXY_PORT="${PROXY_SOCKS5_PORT}"
    fi
  else
    echo "[napcat] proxy requested but PROXY_SOCKS5_HOST/PORT missing, skip proxy."
  fi
else
  echo "[napcat] launching without proxy"
fi

# Build command with --no-sandbox to allow proxychains to work
# (proxychains uses LD_PRELOAD which conflicts with Electron's sandbox/zygote)
NAPCAT_CMD=()
if [[ -x /home/user/QQ.AppImage ]]; then
  NAPCAT_CMD=(/home/user/QQ.AppImage --appimage-extract-and-run --no-sandbox "${EXTRA_FLAGS[@]}")
else
  NAPCAT_CMD=(/home/user/napcat/AppRun --no-sandbox "${EXTRA_FLAGS[@]}")
fi

if [[ "$USE_PROXY" == "true" ]]; then
  write_proxychains_conf "$PROXY_HOST" "$PROXY_PORT"
  echo "[napcat] launching with SOCKS5 proxy ${PROXY_HOST}:${PROXY_PORT}"
  exec proxychains4 -q -f "$PROXYCHAINS_CONF" "${NAPCAT_CMD[@]}"
fi

exec "${NAPCAT_CMD[@]}"
