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
    # 启动 gost (开启详细日志 -V)
    /home/user/gost -V=2 -L "socks5://:${gost_port}?udp=true" -F "${upstream}?udp=true" >/home/user/logs/gost.log 2>&1 &
    gost_pid=$!

    echo "Waiting for proxy to be ready on port ${gost_port}..."
    
    # 循环检查端口是否开启 (最多等 10 秒)
    proxy_ready=0
    for i in {1..10}; do
      if (echo > /dev/tcp/127.0.0.1/${gost_port}) >/dev/null 2>&1; then
        echo "Proxy is ON! (Attempt $i)"
        proxy_ready=1
        break
      fi
      if ! kill -0 $gost_pid 2>/dev/null; then
        echo "ERROR: Gost process died unexpectedly!"
        break
      fi
      sleep 1
    done

    # 如果代理挂了，打印日志并退出
    if [ "$proxy_ready" -eq 0 ]; then
      echo "================ GOST ERROR LOG ================"
      cat /home/user/logs/gost.log
      echo "================================================"
      exit 1
    fi

    # --- [关键修改] 4. 配置 Dante (更严格的排除规则) ---
    cat >/home/user/.dante.conf <<EOF
resolveprotocol: fake

# 1. 排除 IPv4 本地回环 (NapCat WebUI/IPC)
route {
  from: 0.0.0.0/0 to: 127.0.0.0/8
  via: direct
  method: none
}

# 2. [新增] 排除 IPv6 本地回环 (Node.js 经常用 ::1)
route {
  from: 0.0.0.0/0 to: ::1/128
  via: direct
  method: none
}

# 3. [新增] 排除 0.0.0.0 (绑定监听时需要)
route {
  from: 0.0.0.0/0 to: 0.0.0.0/32
  via: direct
  method: none
}

# 4. 其他所有流量走 Gost
route {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  via: 127.0.0.1 port = ${gost_port}
  proxyprotocol: socks_v5
  protocol: tcp udp
  method: none
}
EOF
    echo "Proxy configured successfully."
    
    # 开启后台打印 gost 日志，这样如果连接失败你能立刻在控制台看到原因
    tail -f /home/user/logs/gost.log & 

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