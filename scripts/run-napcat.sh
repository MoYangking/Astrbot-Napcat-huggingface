#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

dante_cmd=()

if [ -n "${QQ_SOCKS5_HOST:-}" ] && [ -n "${QQ_SOCKS5_PORT:-}" ]; then
  socks_host="${QQ_SOCKS5_HOST}"
  socks_port="${QQ_SOCKS5_PORT}"

  # Strip accidental ":port" from host if present (e.g., 1.2.3.4:1080 + PORT=1080)
  if [[ "$socks_host" == *:* ]]; then
    last_part="${socks_host##*:}"
    host_part="${socks_host%:*}"
    if [[ "$last_part" =~ ^[0-9]+$ ]]; then
      socks_host="$host_part"
      [ -z "$socks_port" ] && socks_port="$last_part"
    fi
  fi

  export SOCKS_SERVER="${socks_host}:${socks_port}"
  export SOCKS_VERSION=5
  if [ -n "${QQ_SOCKS5_USER:-}" ]; then
    export SOCKS5_USER="${QQ_SOCKS5_USER}"
  fi
  if [ -n "${QQ_SOCKS5_PASS:-}" ]; then
    export SOCKS5_PASS="${QQ_SOCKS5_PASS}"
  fi

  echo "Using SOCKS5 via ${socks_host}:${socks_port} for QQ (dante socksify)"
  dante_cmd=(socksify)
fi

# Try AppImage extract-and-run first for correct runtime env
if [ -x /home/user/QQ.AppImage ]; then
  exec "${dante_cmd[@]}" /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback to extracted AppRun
exec "${dante_cmd[@]}" /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}
