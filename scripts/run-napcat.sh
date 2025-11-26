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
DEFAULT_PROXY="${NAPCAT_PROXY_DEFAULT:-on}"

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

read -r -a EXTRA_FLAGS <<< "${NAPCAT_FLAGS:-}"

# Gost local proxy port
GOST_LOCAL_PORT="${GOST_LOCAL_PORT:-11080}"
GOST_BIN="/home/user/gost"
GOST_PID_FILE="/tmp/gost-napcat.pid"

# Cleanup gost on exit
cleanup_gost() {
  if [[ -f "$GOST_PID_FILE" ]]; then
    kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
    rm -f "$GOST_PID_FILE"
  fi
}
trap cleanup_gost EXIT

# Build proxy argument for Electron (use native --proxy-server instead of proxychains)
# proxychains uses LD_PRELOAD which conflicts with Electron's sandbox/zygote mechanism
PROXY_ARG=""
if should_enable_proxy; then
  if [[ -n "${PROXY_SOCKS5_HOST:-}" && -n "${PROXY_SOCKS5_PORT:-}" ]]; then
    # If authentication is needed, use gost as local forwarder
    if [[ -n "${PROXY_SOCKS5_USER:-}" ]]; then
      echo "[napcat] starting gost forwarder for authenticated proxy..."
      UPSTREAM="socks5://${PROXY_SOCKS5_USER}:${PROXY_SOCKS5_PASS:-}@${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
      "$GOST_BIN" -L "socks5://:${GOST_LOCAL_PORT}" -F "$UPSTREAM" &
      echo $! > "$GOST_PID_FILE"
      sleep 1  # Wait for gost to start
      PROXY_ARG="--proxy-server=socks5://127.0.0.1:${GOST_LOCAL_PORT}"
      echo "[napcat] launching with SOCKS5 proxy via gost -> ${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
    else
      # No auth, direct connection
      PROXY_ARG="--proxy-server=socks5://${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
      echo "[napcat] launching with SOCKS5 proxy ${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
    fi
  else
    echo "[napcat] proxy requested but PROXY_SOCKS5_HOST/PORT missing, skip proxy."
  fi
else
  echo "[napcat] launching without proxy"
fi

NAPCAT_CMD=()
if [[ -x /home/user/QQ.AppImage ]]; then
  NAPCAT_CMD=(/home/user/QQ.AppImage --appimage-extract-and-run ${PROXY_ARG} "${EXTRA_FLAGS[@]}")
else
  NAPCAT_CMD=(/home/user/napcat/AppRun ${PROXY_ARG} "${EXTRA_FLAGS[@]}")
fi

exec "${NAPCAT_CMD[@]}"
