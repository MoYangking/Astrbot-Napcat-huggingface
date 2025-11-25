#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

PROXYCHAINS_CONF="/home/user/proxychains.conf"
proxy_cmd=()

if [ -n "${QQ_SOCKS5_HOST:-}" ] && [ -n "${QQ_SOCKS5_PORT:-}" ]; then
  proxy_host="${QQ_SOCKS5_HOST}"
  proxy_port="${QQ_SOCKS5_PORT}"

  # Strip accidental ":port" from host if present (common when host already includes port)
  if [[ "$proxy_host" == *:* ]]; then
    last_part="${proxy_host##*:}"
    host_part="${proxy_host%:*}"
    if [[ "$last_part" =~ ^[0-9]+$ ]]; then
      proxy_host="$host_part"
      [ -z "$proxy_port" ] && proxy_port="$last_part"
    fi
  fi

  mkdir -p "$(dirname "$PROXYCHAINS_CONF")"
  cat > "$PROXYCHAINS_CONF" <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
EOF

  if [ -n "${QQ_SOCKS5_USER:-}" ] && [ -n "${QQ_SOCKS5_PASS:-}" ]; then
    echo "socks5 ${proxy_host} ${proxy_port} ${QQ_SOCKS5_USER} ${QQ_SOCKS5_PASS}" >> "$PROXYCHAINS_CONF"
  else
    echo "socks5 ${proxy_host} ${proxy_port}" >> "$PROXYCHAINS_CONF"
  fi

  echo "Using SOCKS5 via ${proxy_host}:${proxy_port} for QQ"
  proxy_cmd=(proxychains4 -f "$PROXYCHAINS_CONF")
fi

# Try AppImage extract-and-run first for correct runtime env
if [ -x /home/user/QQ.AppImage ]; then
  exec "${proxy_cmd[@]}" /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback to extracted AppRun
exec "${proxy_cmd[@]}" /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}
