#!/usr/bin/env bash
set -euo pipefail

# Ensure display env
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# Prefer /app layout to match official images
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

PROXY_STATE_FILE="/home/user/.astrbot-backup/napcat-proxy.json"
PROXYCHAINS_CONF="/home/user/proxychains.conf"
DEFAULT_PROXY="${NAPCAT_PROXY_DEFAULT:-on}"

normalize_bool() {
  local v="${1:-}"
  v="${v,,}"
  case "$v" in
    1|true|on|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

should_enable_proxy() {
  local val=""
  if [[ -f "$PROXY_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r 'if has("enabled") then .enabled else "" end' "$PROXY_STATE_FILE" 2>/dev/null || true)
  fi
  if [[ -z "$val" ]]; then
    val="$DEFAULT_PROXY"
  fi
  if normalize_bool "$val"; then return 0; else return 1; fi
}

ensure_proxy_conf() {
  if [[ -z "${PROXY_SOCKS5_HOST:-}" || -z "${PROXY_SOCKS5_PORT:-}" ]]; then
    echo "[napcat] proxy requested but PROXY_SOCKS5_HOST/PORT missing, skip proxy."
    return 1
  fi
  local auth=""
  if [[ -n "${PROXY_SOCKS5_USER:-}" ]]; then
    auth=" ${PROXY_SOCKS5_USER:-} ${PROXY_SOCKS5_PASS:-}"
  fi
  cat > "$PROXYCHAINS_CONF" <<EOF
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5 ${PROXY_SOCKS5_HOST} ${PROXY_SOCKS5_PORT}${auth}
EOF
  chmod 644 "$PROXYCHAINS_CONF" || true
  echo "[napcat] proxy config written to ${PROXYCHAINS_CONF}"
  return 0
}

read -r -a EXTRA_FLAGS <<< "${NAPCAT_FLAGS:-}"

NAPCAT_CMD=()
if [[ -x /home/user/QQ.AppImage ]]; then
  NAPCAT_CMD=(/home/user/QQ.AppImage --appimage-extract-and-run "${EXTRA_FLAGS[@]}")
else
  NAPCAT_CMD=(/home/user/napcat/AppRun "${EXTRA_FLAGS[@]}")
fi

if should_enable_proxy && ensure_proxy_conf; then
  echo "[napcat] launching with SOCKS5 proxy ${PROXY_SOCKS5_HOST}:${PROXY_SOCKS5_PORT}"
  exec proxychains4 -q -f "$PROXYCHAINS_CONF" "${NAPCAT_CMD[@]}"
fi

echo "[napcat] launching without proxy"
exec "${NAPCAT_CMD[@]}"
