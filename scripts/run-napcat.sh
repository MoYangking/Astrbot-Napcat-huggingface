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
CURL_PROXY_PREFIX=""

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
    CURL_PROXY_PREFIX="$LAUNCH_PREFIX"
fi

extract_appimage() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    if ! (
        cd "$tmpdir"
        "$APPIMAGE_PATH" --appimage-extract >/dev/null
    ); then
        rm -rf "$tmpdir"
        return 1
    fi

    if [ ! -d "$tmpdir/squashfs-root" ]; then
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$NAPCAT_DIR"
    mv "$tmpdir/squashfs-root" "$NAPCAT_DIR"
    rm -rf "$tmpdir"
    return 0
}

download_appimage() {
    local url="${NAPCAT_DOWNLOAD_URL:-}"
    if [ -z "$url" ]; then
        url="$($CURL_PROXY_PREFIX curl -fsSL https://api.github.com/repos/NapNeko/NapCatAppImageBuild/releases/latest \
            | jq -r '.assets[] | select(.name | endswith("-amd64.AppImage")) | .browser_download_url' \
            | head -1)"
    fi
    if [ -z "$url" ]; then
        echo "无法获取 NapCat AppImage 下载链接，请手动设置 NAPCAT_DOWNLOAD_URL。" >&2
        return 1
    fi
    echo "下载新的 NapCat AppImage..."
    $CURL_PROXY_PREFIX curl -L -o "$APPIMAGE_PATH" "$url"
    chmod +x "$APPIMAGE_PATH"
    return 0
}

refresh_appimage_and_extract() {
    download_appimage || return 1
    extract_appimage || return 1
}

# Ensure extracted NapCat tree is healthy (major.node is required for NapCat preload)
ensure_napcat_tree() {
    if [ -f "$MAJOR_NODE_PATH" ]; then
        return
    fi

    if [ ! -x "$APPIMAGE_PATH" ]; then
        echo "NapCat AppImage not found at $APPIMAGE_PATH; attempting to download..." >&2
        refresh_appimage_and_extract || {
            echo "下载或解压 NapCat AppImage 失败，请检查网络/代理配置。" >&2
            exit 1
        }
        if [ -f "$MAJOR_NODE_PATH" ]; then
            return
        fi
    fi

    echo "NapCat extracted files missing or corrupted, re-extracting AppImage..."
    if ! extract_appimage; then
        echo "解压失败，尝试重新下载 AppImage..."
        refresh_appimage_and_extract || {
            echo "重新下载解压 NapCat 仍失败，请手动检查 AppImage。" >&2
            exit 1
        }
    fi

    if [ ! -f "$MAJOR_NODE_PATH" ]; then
        echo "major.node 仍未找到，请确认 NapCat AppImage 是否完整。" >&2
        exit 1
    fi
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
