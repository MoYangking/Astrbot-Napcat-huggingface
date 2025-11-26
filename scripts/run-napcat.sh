#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# Try AppImage extract-and-run first for correct runtime env
# Proxy setup
PROXY_PREFIX=""

# Support for breakdown SOCKS5 env vars
if [ -n "${PROXY_SOCKS5_HOST:-}" ] && [ -n "${PROXY_SOCKS5_PORT:-}" ]; then
    NAPCAT_PROXY="socks5 ${PROXY_SOCKS5_HOST} ${PROXY_SOCKS5_PORT}"
    if [ -n "${PROXY_SOCKS5_USER:-}" ] && [ -n "${PROXY_SOCKS5_PASS:-}" ]; then
        NAPCAT_PROXY="${NAPCAT_PROXY} ${PROXY_SOCKS5_USER} ${PROXY_SOCKS5_PASS}"
    fi
fi

if [ -n "${NAPCAT_PROXY:-}" ]; then
    echo "[NapCat] Proxy enabled: $NAPCAT_PROXY"
    
    # Create local proxychains config
    cat > "$HOME/proxychains.conf" <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
$NAPCAT_PROXY
EOF
    
    export PROXYCHAINS_CONF_FILE="$HOME/proxychains.conf"
    # Use -q to suppress proxychains log spam if needed, but standard output is often useful for debugging
    PROXY_PREFIX="proxychains4"
fi

if [ -x /home/user/QQ.AppImage ]; then
  exec $PROXY_PREFIX /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback to extracted AppRun
exec $PROXY_PREFIX /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}
