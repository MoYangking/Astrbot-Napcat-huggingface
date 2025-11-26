#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# 检查是否需要启用代理
PROXY_ENABLED_FILE="/home/user/.proxy-enabled"
if [ -f "$PROXY_ENABLED_FILE" ]; then
  echo "[NapCat] Proxy enabled, setting proxy environment variables..."
  export http_proxy="http://127.0.0.1:8118"
  export https_proxy="http://127.0.0.1:8118"
  export HTTP_PROXY="http://127.0.0.1:8118"
  export HTTPS_PROXY="http://127.0.0.1:8118"
  echo "[NapCat] Using proxy: $http_proxy"
else
  echo "[NapCat] Proxy disabled, using direct connection..."
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

# Try AppImage extract-and-run first for correct runtime env
if [ -x /home/user/QQ.AppImage ]; then
  exec /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback to extracted AppRun
exec /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}
