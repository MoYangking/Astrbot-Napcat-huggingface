#!/usr/bin/env bash
# Manage tun2socks transparent proxy for NapCat (QQ) traffic.
# Supports enable/disable/status. Designed to be called by OpenResty admin API.

set -euo pipefail

BASE_DIR="/home/user/proxy"
CONFIG_FILE="${BASE_DIR}/config.json"
STATUS_FILE="${BASE_DIR}/status.json"
PID_FILE="${BASE_DIR}/tun2socks.pid"
TUN2SOCKS_BIN="/home/user/tun2socks"
LOG_DIR="/home/user/logs"
LOG_FILE="${LOG_DIR}/tun2socks.log"
CHAIN="PROXY_TUN2SOCKS"

mkdir -p "${BASE_DIR}" "${LOG_DIR}"

log() { printf '[proxy] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

default_bool() {
  local v="${1:-false}"
  case "${v,,}" in
    1|true|yes|on) echo true ;;
    *) echo false ;;
  esac
}

init_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    return
  fi
  python3 - "${CONFIG_FILE}" <<'PY'
import json, os, sys, pathlib

def as_int(val, default):
    try:
        return int(val)
    except Exception:
        return default

cfg = {
    "mode": "tun2socks",
    "socks_host": os.getenv("PROXY_SOCKS5_HOST", ""),
    "socks_port": as_int(os.getenv("PROXY_SOCKS5_PORT", "1080") or 1080, 1080),
    "socks_user": os.getenv("PROXY_SOCKS5_USER", ""),
    "socks_pass": os.getenv("PROXY_SOCKS5_PASS", ""),
    "dns": os.getenv("PROXY_DNS", ""),
    "uid": as_int(os.getenv("PROXY_UID", "1000") or 1000, 1000),
    "mark": as_int(os.getenv("PROXY_FWMARK", "1") or 1, 1),
    "table": as_int(os.getenv("PROXY_TABLE", "100") or 100, 100),
    "tun_dev": os.getenv("PROXY_TUN_DEV", "tun0"),
    "tun_addr": os.getenv("PROXY_TUN_ADDR", "10.10.0.1/24"),
    "auto_enable": os.getenv("PROXY_AUTO_ENABLE", "").lower() in ("1", "true", "yes", "on"),
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(cfg, ensure_ascii=False))
PY
}

load_config() {
  init_config
  local cfg
  cfg="$(cat "${CONFIG_FILE}")"
  socks_host="$(jq -r '.socks_host // ""' <<<"${cfg}")"
  socks_port="$(jq -r '.socks_port // 1080' <<<"${cfg}")"
  socks_user="$(jq -r '.socks_user // ""' <<<"${cfg}")"
  socks_pass="$(jq -r '.socks_pass // ""' <<<"${cfg}")"
  socks_dns="$(jq -r '.dns // ""' <<<"${cfg}")"
  proxy_uid="$(jq -r '.uid // 1000' <<<"${cfg}")"
  proxy_mark="$(jq -r '.mark // 1' <<<"${cfg}")"
  proxy_table="$(jq -r '.table // 100' <<<"${cfg}")"
  tun_dev="$(jq -r '.tun_dev // "tun0"' <<<"${cfg}")"
  tun_addr="$(jq -r '.tun_addr // "10.10.0.1/24"' <<<"${cfg}")"
  auto_enable="$(default_bool "$(jq -r '.auto_enable // false' <<<"${cfg}")")"
}

require_tools() {
  for c in ip iptables jq "${TUN2SOCKS_BIN}" python3; do
    command -v "${c%% *}" >/dev/null 2>&1 || fail "缺少依赖: ${c}"
  done
  [[ -c /dev/net/tun ]] || fail "/dev/net/tun 不存在，容器需 --cap-add=NET_ADMIN --device /dev/net/tun"
}

resolve_ip() {
  local host="$1" ip=""
  if [[ "${host}" =~ ^[0-9.]+$ ]]; then
    echo "${host}"; return 0
  fi
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "${host}" | awk 'NR==1 {print $1}')"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(ping -n -c 1 -W 1 "${host}" 2>/dev/null | awk 'NR==1 {gsub(/[()]/,"",$3); print $3}')"
  fi
  echo "${ip}"
}

is_running() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid; pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi
  pgrep -f "tun2socks.*tun://${tun_dev}" >/dev/null 2>&1
}

tun_up() {
  ip link show "${tun_dev}" >/dev/null 2>&1 && ip addr show "${tun_dev}" | grep -q .
}

chain_hooked() {
  iptables -t mangle -C OUTPUT -j "${CHAIN}" >/dev/null 2>&1
}

policy_exists() {
  ip rule show | grep -q "fwmark ${proxy_mark} .* table ${proxy_table}"
}

print_status() {
  local running="${1:-false}" tun="${2:-false}" hook="${3:-false}" rule="${4:-false}" proxy_ip="${5:-}" message="${6:-}" err="${7:-}"
  local payload
  payload="$(python3 - "${CONFIG_FILE}" "${running}" "${tun}" "${hook}" "${rule}" "${proxy_ip}" "${message}" "${err}" <<'PY'
import json,sys
cfg_path, running, tun, hook, rule, proxy_ip, message, err = sys.argv[1:]
def b(v): return v.lower() == "true"
try:
    cfg = json.load(open(cfg_path))
except Exception:
    cfg = {}
cfg.setdefault("mode", "tun2socks")
out = {
    "enabled": b(running) and b(tun) and b(hook) and b(rule),
    "running": b(running),
    "tun_up": b(tun),
    "iptables_attached": b(hook),
    "policy_rule": b(rule),
    "proxy_ip": None if proxy_ip in ("", "null") else proxy_ip,
    "message": message,
    "error": None if err == "" else err,
    "config": cfg
}
print(json.dumps(out, ensure_ascii=False))
PY
)" || true
  [[ -n "${payload:-}" ]] && echo "${payload}" | tee "${STATUS_FILE}" >/dev/null || true
}

ensure_tun() {
  if ! ip link show "${tun_dev}" >/dev/null 2>&1; then
    ip tuntap add dev "${tun_dev}" mode tun
  fi
  ip addr show "${tun_dev}" | grep -q "${tun_addr}" >/dev/null 2>&1 || ip addr add "${tun_addr}" dev "${tun_dev}" || true
  ip link set "${tun_dev}" up
}

setup_chain() {
  local proxy_ip="$1"
  iptables -t mangle -N "${CHAIN}" 2>/dev/null || true
  iptables -t mangle -F "${CHAIN}" || true

  iptables -t mangle -A "${CHAIN}" -d 127.0.0.0/8 -j RETURN
  iptables -t mangle -A "${CHAIN}" -d 10.0.0.0/8 -j RETURN
  iptables -t mangle -A "${CHAIN}" -d 172.16.0.0/12 -j RETURN
  iptables -t mangle -A "${CHAIN}" -d 192.168.0.0/16 -j RETURN
  iptables -t mangle -A "${CHAIN}" -d 169.254.0.0/16 -j RETURN
  iptables -t mangle -A "${CHAIN}" -d 224.0.0.0/4 -j RETURN
  iptables -t mangle -A "${CHAIN}" -d 255.255.255.255/32 -j RETURN
  if [[ -n "${proxy_ip}" ]]; then
    iptables -t mangle -A "${CHAIN}" -d "${proxy_ip}"/32 -j RETURN
  fi

  iptables -t mangle -A "${CHAIN}" -m owner --uid-owner "${proxy_uid}" -p tcp -j MARK --set-mark "${proxy_mark}"
  iptables -t mangle -A "${CHAIN}" -m owner --uid-owner "${proxy_uid}" -p udp -j MARK --set-mark "${proxy_mark}"

  chain_hooked || iptables -t mangle -A OUTPUT -j "${CHAIN}"
}

setup_policy() {
  ip rule add fwmark "${proxy_mark}" table "${proxy_table}" >/dev/null 2>&1 || true
  ip route replace default dev "${tun_dev}" table "${proxy_table}"
  ip route flush cache || true
}

build_proxy_uri() {
  python3 - "${socks_user}" "${socks_pass}" "${socks_host}" "${socks_port}" <<'PY'
import sys, urllib.parse
user, pwd, host, port = sys.argv[1:]
auth = ""
if user or pwd:
    auth = urllib.parse.quote(user) + ":" + urllib.parse.quote(pwd) + "@"
print(f"socks5://{auth}{host}:{port}")
PY
}

start_tun2socks() {
  [[ -n "${socks_host}" ]] || fail "未设置 SOCKS5 主机"
  [[ -n "${socks_port}" ]] || fail "未设置 SOCKS5 端口"

  if is_running; then
    log "tun2socks 已在运行，先重启"
    stop_tun2socks
  fi

  local proxy_uri dns_args=()
  proxy_uri="$(build_proxy_uri)"
  if [[ -n "${socks_dns}" ]]; then
    dns_args=(-dns "${socks_dns}")
  fi

  nohup "${TUN2SOCKS_BIN}" \
    -device "tun://${tun_dev}" \
    -proxy "${proxy_uri}" \
    "${dns_args[@]}" \
    -loglevel warn \
    -udp-timeout 60s \
    >> "${LOG_FILE}" 2>&1 &
  echo $! > "${PID_FILE}"
}

stop_tun2socks() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid; pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]]; then
      kill "${pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
  fi
  pkill -f "tun2socks.*tun://${tun_dev}" 2>/dev/null || true
}

cleanup_network() {
  chain_hooked && iptables -t mangle -D OUTPUT -j "${CHAIN}" >/dev/null 2>&1 || true
  iptables -t mangle -F "${CHAIN}" >/dev/null 2>&1 || true
  iptables -t mangle -X "${CHAIN}" >/dev/null 2>&1 || true

  ip rule del fwmark "${proxy_mark}" table "${proxy_table}" >/dev/null 2>&1 || true
  ip route flush table "${proxy_table}" >/dev/null 2>&1 || true

  ip link del "${tun_dev}" >/dev/null 2>&1 || true
}

cmd_status() {
  load_config
  local proxy_ip; proxy_ip="$(resolve_ip "${socks_host}")"
  local running="false" tun="false" hook="false" rule="false"
  is_running && running="true"
  tun_up && tun="true"
  chain_hooked && hook="true"
  policy_exists && rule="true"
  print_status "${running}" "${tun}" "${hook}" "${rule}" "${proxy_ip}" "ok"
}

cmd_disable() {
  load_config
  stop_tun2socks
  cleanup_network
  print_status "false" "false" "false" "false" "" "disabled"
}

cmd_enable() {
  load_config
  require_tools
  [[ -n "${socks_host}" ]] || fail "SOCKS5 主机未配置"
  [[ -n "${socks_port}" ]] || fail "SOCKS5 端口未配置"

  local proxy_ip; proxy_ip="$(resolve_ip "${socks_host}")"
  [[ -n "${proxy_ip}" ]] || fail "无法解析代理服务器 IP: ${socks_host}"

  ensure_tun
  setup_chain "${proxy_ip}"
  setup_policy
  start_tun2socks

  local running="false" tun="false" hook="false" rule="false"
  is_running && running="true"
  tun_up && tun="true"
  chain_hooked && hook="true"
  policy_exists && rule="true"
  print_status "${running}" "${tun}" "${hook}" "${rule}" "${proxy_ip}" "enabled"
}

case "${1:-}" in
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  status|"") cmd_status ;;
  *)
    echo "用法: $0 [enable|disable|status]" >&2
    exit 1
    ;;
esac
