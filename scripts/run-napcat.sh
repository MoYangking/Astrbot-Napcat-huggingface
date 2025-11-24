#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

NAPCAT_SOCKS5="${NAPCAT_SOCKS5:-}"
NAPCAT_SOCKS5_USER="${NAPCAT_SOCKS5_USER:-}"
NAPCAT_SOCKS5_PASS="${NAPCAT_SOCKS5_PASS:-}"
NAPCAT_PROXYCHAINS_CONF="${NAPCAT_PROXYCHAINS_CONF:-/home/user/.proxychains.conf}"

NAPCAT_FLAGS_ARRAY=()
if [[ -n "${NAPCAT_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  NAPCAT_FLAGS_ARRAY=(${NAPCAT_FLAGS})
fi

PROXY_PREFIX=()
if [[ -n "${NAPCAT_SOCKS5}" ]]; then
  PROXY_ADDR="$NAPCAT_SOCKS5"
  if [[ "$PROXY_ADDR" != *" "* && "$PROXY_ADDR" == *:* ]]; then
    PROXY_ADDR="${PROXY_ADDR/:/ }"
  fi

  read -r PROXY_HOST PROXY_PORT <<<"$PROXY_ADDR"

  PROXY_LINE="socks5 $PROXY_HOST $PROXY_PORT"
  if [[ -n "$NAPCAT_SOCKS5_USER" ]]; then
    PROXY_LINE+=" $NAPCAT_SOCKS5_USER ${NAPCAT_SOCKS5_PASS:-}"
  fi

  mkdir -p "$(dirname "$NAPCAT_PROXYCHAINS_CONF")"
  cat > "$NAPCAT_PROXYCHAINS_CONF" <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
$PROXY_LINE
EOF
  PROXY_PREFIX=(proxychains4 -f "$NAPCAT_PROXYCHAINS_CONF")
fi

if [ -x /home/user/QQ.AppImage ]; then
  TARGET=(/home/user/QQ.AppImage --appimage-extract-and-run)
else
  TARGET=(/home/user/napcat/AppRun)
fi

if ((${#PROXY_PREFIX[@]})); then
  exec "${PROXY_PREFIX[@]}" "${TARGET[@]}" "${NAPCAT_FLAGS_ARRAY[@]}"
else
  exec "${TARGET[@]}" "${NAPCAT_FLAGS_ARRAY[@]}"
fi
