#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true
# Ensure QQ crash dir exists to avoid noisy Bugly open-file errors
mkdir -p /app/.config/QQ/crash_files || true
[ -f /app/.config/QQ/crash_files/rqd_record.eup ] || : > /app/.config/QQ/crash_files/rqd_record.eup

# Bump file descriptors; ignore failure on restricted systems
ulimit -n 65535 || true

# Wait briefly for network to reduce early packet timeouts
if command -v curl >/dev/null 2>&1; then
  for i in $(seq 1 10); do
    if curl -fsSL -m 2 https://www.qq.com >/dev/null 2>&1; then break; fi
    sleep 1
  done
fi

# Try AppImage extract-and-run first for correct runtime env
if [ -x /home/user/QQ.AppImage ]; then
  exec /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# Fallback to extracted AppRun
exec /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}

