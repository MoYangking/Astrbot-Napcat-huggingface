#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# Check proxy status from state file
PROXY_STATE_FILE="/home/user/.astrbot-backup/napcat-proxy.json"
USE_PROXY="false"

# Default from environment variable
PROXY_DEFAULT="${NAPCAT_PROXY_DEFAULT:-on}"
if [ "$PROXY_DEFAULT" = "on" ] || [ "$PROXY_DEFAULT" = "true" ] || [ "$PROXY_DEFAULT" = "1" ]; then
    USE_PROXY="true"
fi

# Override from state file if exists
if [ -f "$PROXY_STATE_FILE" ]; then
    STATE_ENABLED=$(cat "$PROXY_STATE_FILE" 2>/dev/null | grep -o '"enabled":[^,}]*' | cut -d':' -f2 | tr -d ' ')
    if [ "$STATE_ENABLED" = "true" ]; then
        USE_PROXY="true"
    elif [ "$STATE_ENABLED" = "false" ]; then
        USE_PROXY="false"
    fi
fi

echo "[run-napcat] Proxy enabled: $USE_PROXY"

# Determine the command to run
NAPCAT_CMD=""
if [ -x /home/user/QQ.AppImage ]; then
    NAPCAT_CMD="/home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}"
else
    NAPCAT_CMD="/home/user/napcat/AppRun ${NAPCAT_FLAGS:-}"
fi

# Run with or without graftcp proxy
if [ "$USE_PROXY" = "true" ]; then
    echo "[run-napcat] Starting NapCat with graftcp proxy..."
    exec /home/user/graftcp $NAPCAT_CMD
else
    echo "[run-napcat] Starting NapCat without proxy..."
    exec $NAPCAT_CMD
fi
