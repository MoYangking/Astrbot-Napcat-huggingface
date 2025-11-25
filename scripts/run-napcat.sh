#!/usr/bin/env bash
set -euo pipefail

# --- 1. 环境初始化 ---
export DISPLAY="${DISPLAY:-:1}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

dante_cmd=()

# --- 2. 代理准备 ---
if [ -n "${QQ_SOCKS5_HOST:-}" ] && [ -n "${QQ_SOCKS5_PORT:-}" ]; then
  socks_host="${QQ_SOCKS5_HOST}"
  socks_port="${QQ_SOCKS5_PORT}"

  # 修正 host:port 格式
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

  # --- 3. 启动 Gost 并进行健康检查 ---
  if [ -x /home/user/gost ]; then
    mkdir -p /home/user/logs
    
    echo "Starting gost bridge..."
    # 启动 gost
    /home/user/gost -L "socks5://:${gost_port}?udp=true" -F "${upstream}?udp=true" >/home/user/logs/gost.log 2>&1 &
    gost_pid=$!

    echo "Waiting for proxy to be ready on port ${gost_port}..."
    
    # 循环检查端口是否开启 (最多等 10 秒)
    proxy_ready=0
    for i in {1..10}; do
      # 使用 bash 内置 tcp 检测
      if (echo > /dev/tcp/127.0.0.1/${gost_port}) >/dev/null 2>&1; then
        echo "Proxy is ON! (Attempt $i)"
        proxy_ready=1
        break
      fi
      # 检查进程是否已经挂了
      if ! kill -0 $gost_pid 2>/dev/null; then
        echo "ERROR: Gost process died unexpectedly!"
        break
      fi
      sleep 1
    done

    # 如果代理没准备好，打印日志并退出！
    if [ "$proxy_ready" -eq 0 ]; then
      echo "================ GOST ERROR LOG ================"
      cat /home/user/logs/gost.log
      echo "================================================"
      echo "Fatal Error: Local proxy failed to start. Cannot start QQ."
      exit 1
    fi

    # --- 4. 配置 Dante ---
    cat >/home/user/.dante.conf <<EOF
resolveprotocol: fake

# 直连本地回环，防止 WebUI 报错
route {
  from: 0.0.0.0/0 to: 127.0.0.0/8
  via: direct
  method: none
}

# 其他流量走 Gost
route {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  via: 127.0.0.1 port = ${gost_port}
  proxyprotocol: socks_v5
  protocol: tcp udp
  method: none
}
EOF
    echo "Proxy configured successfully."
    dante_cmd=(env SOCKS_CONF=/home/user/.dante.conf socksify)
  else
    echo "WARN: gost binary not found. Running DIRECT."
  fi
fi

# --- 5. 启动 QQ ---
echo "Launching NapCat..."

if [ -x /home/user/QQ.AppImage ]; then
  exec "${dante_cmd[@]}" /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

exec "${dante_cmd[@]}" /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}