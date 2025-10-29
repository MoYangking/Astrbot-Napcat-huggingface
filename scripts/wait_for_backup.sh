#!/usr/bin/env bash
# -*- coding: utf-8 -*-

set -euo pipefail

LANG=${LANG:-C.UTF-8}
export LANG

# 与 backup_to_github.sh 对齐的默认路径
BACKUP_REPO_DIR=${BACKUP_REPO_DIR:-/home/user/.astrbot-backup}
HIST_DIR=${HIST_DIR:-$BACKUP_REPO_DIR}
READINESS_FILE=${READINESS_FILE:-}
if [[ -z "${READINESS_FILE}" ]]; then
  READINESS_FILE="$HIST_DIR/.backup.ready"
fi
SESSION_FILE="$HIST_DIR/.backup.session"
ADMIN_CONFIG="/home/user/nginx/admin_config.json"
BACKUP_WAIT_TIMEOUT=${BACKUP_WAIT_TIMEOUT:-0}  # 0 表示无限等待

log() {
  echo "[waiter] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

is_ready_for_current_session() {
  local ready_file="$1"
  # 要求当前会话标识存在
  [[ -f "$SESSION_FILE" ]] || return 1
  # 方式一：就绪文件内容包含会话 ID（backup 脚本会写入）
  if grep -q -F "$(cat "$SESSION_FILE" 2>/dev/null || echo)" "$ready_file" 2>/dev/null; then
    return 0
  fi
  # 方式二：就绪文件的 mtime 晚于会话文件（同一轮启动）
  if stat -c %Y "$ready_file" >/dev/null 2>&1 && stat -c %Y "$SESSION_FILE" >/dev/null 2>&1; then
    local rts sts
    rts=$(stat -c %Y "$ready_file")
    sts=$(stat -c %Y "$SESSION_FILE")
    [[ "$rts" -ge "$sts" ]] && return 0
  fi
  return 1
}

wait_for_ready() {
  local waited=0
  local step=1
  log "等待备份初始化完成，检测就绪文件：$READINESS_FILE (超时: ${BACKUP_WAIT_TIMEOUT}s, 0=不超时)"
  while true; do
    # 优先等待会话文件，避免复用历史 .backup.ready
    if [[ ! -f "$SESSION_FILE" ]]; then
      if (( BACKUP_WAIT_TIMEOUT > 0 && waited >= BACKUP_WAIT_TIMEOUT )); then
        log "未检测到会话文件($SESSION_FILE)，但已超时，继续启动"
        return 0
      fi
      sleep "$step"; waited=$((waited+step)); continue
    fi

    # 支持多候选路径，兼容不同脚本默认
    for candidate in "$READINESS_FILE" "$HIST_DIR/.backup.ready" "$BACKUP_REPO_DIR/.backup.ready" "/home/user/.astrbot-backup/.backup.ready"; do
      if [[ -f "$candidate" ]] && is_ready_for_current_session "$candidate"; then
        # 关键文件就绪校验：避免 nginx 首次写默认覆盖备份版本
        if [[ -e "$ADMIN_CONFIG" ]]; then
          log "检测到当前会话就绪且关键文件已到位：$candidate"
          return 0
        else
          log "已就绪但关键文件未到位，继续等待：$ADMIN_CONFIG"
        fi
      fi
    done

    if (( BACKUP_WAIT_TIMEOUT > 0 && waited >= BACKUP_WAIT_TIMEOUT )); then
      log "等待超时(${BACKUP_WAIT_TIMEOUT}s)，继续启动（不再阻塞）"
      return 0
    fi
    sleep "$step"; waited=$((waited+step))
  done
}

wait_for_ready

