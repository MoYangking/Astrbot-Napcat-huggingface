#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

dante_cmd=()

if [ -n "${QQ_SOCKS5_HOST:-}" ] && [ -n "${QQ_SOCKS5_PORT:-}" ]; then
  socks_host="${QQ_SOCKS5_HOST}"
  socks_port="${QQ_SOCKS5_PORT}"

  # Strip accidental ":port" logic (unchanged)
  if [[ "$socks_host" == *:* ]]; then
    last_part="${socks_host##*:}"
    host_part="${socks_host%:*}"
    if [[ "$last_part" =~ ^[0-9]+$ ]]; then
      socks_host="$host_part"
      [ -z "$socks_port" ] && socks_port="$last_part"
    fi
  fi

  gost_port="${GOST_LOCAL_SOCKS_PORT:-1081}"
  upstream="socks5://${socks_host}:${socks_port}"
  if [ -n "${QQ_SOCKS5_USER:-}" ] || [ -n "${QQ_SOCKS5_PASS:-}" ]; then
    upstream="socks5://${QQ_SOCKS5_USER:-}:${QQ_SOCKS5_PASS:-}@${socks_host}:${socks_port}"
  fi

  # [Fix 1]: Logic flow - Only enable dante_cmd if gost exists and starts
  if [ -x /home/user/gost ]; then
    mkdir -p /home/user/logs
    # Enable UDP
    (/home/user/gost -L "socks5://:${gost_port}?udp=true" -F "${upstream}?udp=true" >/home/user/logs/gost.log 2>&1 &)
    
    # Wait a bit for gost to be ready
    sleep 1

    # [Fix 2]: Add resolveprotocol: fake for DNS over SOCKS
    cat >/home/user/.dante.conf <<EOF
resolveprotocol: fake
route {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  via: 127.0.0.1 port = ${gost_port}
  proxyprotocol: socks_v5
  protocol: tcp udp
  method: none
}
EOF

    echo "Using SOCKS5 via ${socks_host}:${socks_port} (via local gost :${gost_port})"
    dante_cmd=(env SOCKS_CONF=/home/user/.dante.conf socksify)
  else
    echo "WARN: /home/user/gost not found. Running WITHOUT proxy." >&2
    # Do NOT set dante_cmd here, so QQ runs directly
  fi
fi

# Try AppImage
if [ -x /home/user/QQ.AppImage ]; then
  exec "${dante_cmd[@]}" /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback
exec "${dante_cmd[@]}" /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}