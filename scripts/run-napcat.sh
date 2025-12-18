#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

LOG_DIR="/home/user/logs"
mkdir -p "${LOG_DIR}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# SOCKS5 proxy forwarding via gost (disabled)
: <<'GOST_DISABLED'
# Environment variables: PROXY_SOCKS5_HOST, PROXY_SOCKS5_PORT, PROXY_SOCKS5_USER, PROXY_SOCKS5_PASS
GOST_LOCAL_PORT=10800
if [ -n "${PROXY_SOCKS5_HOST:-}" ] && [ -n "${PROXY_SOCKS5_PORT:-}" ]; then
  echo "[napcat] Starting gost proxy forwarder..."

  if [ -n "${PROXY_SOCKS5_USER:-}" ] && [ -n "${PROXY_SOCKS5_PASS:-}" ]; then
    # Authenticated SOCKS5 proxy
    /home/user/gost -L ":${GOST_LOCAL_PORT}" -F "socks5://${PROXY_SOCKS5_USER}:${PROXY_SOCKS5_PASS}@${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}" >> "${LOG_DIR}/gost.log" 2>&1 &
    echo "[napcat] gost forwarding to ${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT} (authenticated)"
  else
    # Non-authenticated SOCKS5 proxy
    /home/user/gost -L ":${GOST_LOCAL_PORT}" -F "socks5://${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}" >> "${LOG_DIR}/gost.log" 2>&1 &
    echo "[napcat] gost forwarding to ${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
  fi

  # Wait for gost to start
  sleep 1

  # Set NapCat proxy environment variables
  export NAPCAT_PROXY_ADDRESS="127.0.0.1"
  export NAPCAT_PROXY_PORT="${GOST_LOCAL_PORT}"
  echo "[napcat] NapCat proxy set to 127.0.0.1:${GOST_LOCAL_PORT}"
fi
GOST_DISABLED

# Try AppImage extract-and-run first for correct runtime env
if [ -x /home/user/QQ.AppImage ]; then
  exec /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback to extracted AppRun
exec /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}
