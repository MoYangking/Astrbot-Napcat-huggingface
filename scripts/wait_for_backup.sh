#!/usr/bin/env bash
# -*- coding: utf-8 -*-

set -euo pipefail

LANG=${LANG:-C.UTF-8}
export LANG

# 读取与 backup_to_github.sh 相同的默认路径
BACKUP_REPO_DIR=${BACKUP_REPO_DIR:-/home/user/.astrbot-backup}
READINESS_FILE=${READINESS_FILE:-$BACKUP_REPO_DIR/.backup.ready}
BACKUP_WAIT_TIMEOUT=${BACKUP_WAIT_TIMEOUT:-0}  # 0 表示无限等待

log() {
  echo "[waiter] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

wait_for_ready() {
  local waited=0
  local step=1
  log "等待备份初始化完成，检测就绪文件：$READINESS_FILE (超时: ${BACKUP_WAIT_TIMEOUT}s, 0=不超时)"
  while true; do
    if [[ -f "$READINESS_FILE" ]]; then
      log "检测到就绪文件，继续启动后续进程"
      return 0
    fi
    if (( BACKUP_WAIT_TIMEOUT > 0 && waited >= BACKUP_WAIT_TIMEOUT )); then
      log "等待超时(${BACKUP_WAIT_TIMEOUT}s)，继续启动（不再阻塞）"
      return 0
    fi
    sleep "$step"
    waited=$((waited+step))
  done
}

wait_for_ready

