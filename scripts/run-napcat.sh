#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# AppImage/extracted paths
APPIMAGE_PATH="${APPIMAGE_PATH:-/home/user/QQ.AppImage}"
NAPCAT_DIR="${NAPCAT_DIR:-/home/user/napcat}"
MAJOR_NODE_PATH="$NAPCAT_DIR/resources/app/major.node"

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

# Ensure extracted NapCat tree is healthy (major.node is required for NapCat preload)
ensure_napcat_tree() {
    if [ -f "$MAJOR_NODE_PATH" ]; then
        return
    fi

    if [ ! -x "$APPIMAGE_PATH" ]; then
        echo "NapCat AppImage not found at $APPIMAGE_PATH; cannot repair extracted files." >&2
        exit 1
    fi

    echo "NapCat extracted files missing or corrupted, re-extracting AppImage..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    (
        cd "$tmpdir"
        "$APPIMAGE_PATH" --appimage-extract >/dev/null
    )
    rm -rf "$NAPCAT_DIR"
    mv "$tmpdir/squashfs-root" "$NAPCAT_DIR"
    rm -rf "$tmpdir"
}

ensure_napcat_tree

# Prefer already extracted AppRun to avoid repeated /tmp extractions (keeps major.node around)
if [ -x "$NAPCAT_DIR/AppRun" ]; then
    export APPDIR="$NAPCAT_DIR"
    if [ -f "$APPIMAGE_PATH" ]; then
        export APPIMAGE="$APPIMAGE_PATH"
    fi
    exec $LAUNCH_PREFIX "$NAPCAT_DIR/AppRun" ${NAPCAT_FLAGS:-}
fi

# Fallback to AppImage if extraction directory vanished
if [ -x "$APPIMAGE_PATH" ]; then
    exec $LAUNCH_PREFIX "$APPIMAGE_PATH" --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

echo "No runnable NapCat binaries found (checked $NAPCAT_DIR/AppRun and $APPIMAGE_PATH)." >&2
exit 1
