#!/usr/bin/env bash
set -euo pipefail

# --- 1. 环境初始化 ---
# 确保显示环境
export DISPLAY="${DISPLAY:-:1}"
# 禁用硬件加速，防止 GPU 报错
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# 统一 HOME 目录 (匹配官方镜像习惯)
export HOME="/app"
export XDG_CONFIG_HOME="/app/.config"
mkdir -p /app/.config/QQ /app/napcat/config || true

# 初始化命令数组，默认空（直连）
dante_cmd=()

# --- 2. 代理逻辑处理 ---
if [ -n "${QQ_SOCKS5_HOST:-}" ] && [ -n "${QQ_SOCKS5_PORT:-}" ]; then
  socks_host="${QQ_SOCKS5_HOST}"
  socks_port="${QQ_SOCKS5_PORT}"

  # 处理 host:port 格式 (例如传入了 1.2.3.4:1080)
  if [[ "$socks_host" == *:* ]]; then
    last_part="${socks_host##*:}"
    host_part="${socks_host%:*}"
    if [[ "$last_part" =~ ^[0-9]+$ ]]; then
      socks_host="$host_part"
      [ -z "$socks_port" ] && socks_port="$last_part"
    fi
  fi

  # 设置 Gost 转换端口和上游地址
  gost_port="${GOST_LOCAL_SOCKS_PORT:-1081}"
  upstream="socks5://${socks_host}:${socks_port}"
  
  # 如果有账号密码，拼接到 URL 中
  if [ -n "${QQ_SOCKS5_USER:-}" ] || [ -n "${QQ_SOCKS5_PASS:-}" ]; then
    upstream="socks5://${QQ_SOCKS5_USER:-}:${QQ_SOCKS5_PASS:-}@${socks_host}:${socks_port}"
  fi

  # --- 3. 启动 Gost 桥接 ---
  # 必须存在 gost 文件才执行
  if [ -x /home/user/gost ]; then
    mkdir -p /home/user/logs
    
    echo "Starting local gost bridge on port ${gost_port}..."
    # 启动 gost 后台运行，开启 UDP 支持
    (/home/user/gost -L "socks5://:${gost_port}?udp=true" -F "${upstream}?udp=true" >/home/user/logs/gost.log 2>&1 &)
    
    # 关键：等待几秒确保 gost 已经启动监听，防止 socksify 连不上报错 ECONNREFUSED
    sleep 5

    # --- 4. 生成 Dante 配置文件 ---
    # resolveprotocol: fake -> 强制远程 DNS 解析
    # route -> 127.0.0.0/8 direct -> 本地回环不走代理 (修复 WebUI 连接失败)
    cat >/home/user/.dante.conf <<EOF
resolveprotocol: fake

route {
  from: 0.0.0.0/0 to: 127.0.0.0/8
  via: direct
  method: none
}

route {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  via: 127.0.0.1 port = ${gost_port}
  proxyprotocol: socks_v5
  protocol: tcp udp
  method: none
}
EOF

    echo "Using SOCKS5 Proxy via local bridge (127.0.0.1:${gost_port})"
    # 设置 socksify 环境变量
    dante_cmd=(env SOCKS_CONF=/home/user/.dante.conf socksify)
  else
    echo "WARN: /home/user/gost not found. Skipping proxy setup. Running DIRECT connection." >&2
  fi
fi

# --- 5. 启动 QQ/NapCat ---

# 优先尝试 AppImage (如果存在)
if [ -x /home/user/QQ.AppImage ]; then
  echo "Starting QQ.AppImage..."
  exec "${dante_cmd[@]}" /home/user/QQ.AppImage --appimage-extract-and-run ${NAPCAT_FLAGS:-}
fi

# 回退到 AppRun (如果解压版存在)
echo "Starting NapCat via AppRun..."
exec "${dante_cmd[@]}" /home/user/napcat/AppRun ${NAPCAT_FLAGS:-}