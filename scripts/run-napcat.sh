#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# Proxy Configuration
PROXY_ENABLE="${PROXY_ENABLE:-false}"
LAUNCH_PREFIX=""

if [ "$PROXY_ENABLE" = "true" ]; then
    echo "Configuring Proxychains..."
    PROXY_TYPE="${PROXY_TYPE:-socks5}"
    PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
    PROXY_PORT="${PROXY_PORT:-1080}"
    PROXY_USER="${PROXY_USER:-}"
    PROXY_PASS="${PROXY_PASS:-}"

    # Create config file
    cat > /app/.config/proxychains4.conf <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
EOF

    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        echo "$PROXY_TYPE $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS" >> /app/.config/proxychains4.conf
    else
        echo "$PROXY_TYPE $PROXY_HOST $PROXY_PORT" >> /app/.config/proxychains4.conf
    fi

    LAUNCH_PREFIX="proxychains4 -f /app/.config/proxychains4.conf"
fi

# Always use extracted AppRun to avoid proxychains conflicts with AppImage mounting
# When proxychains is enabled, it interferes with AppImage's FUSE filesystem operations
exec $LAUNCH_PREFIX /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}
