#!/usr/bin/env bash
# -*- coding: utf-8 -*-

set -euo pipefail

LANG=${LANG:-C.UTF-8}
export LANG

# 与 backup_to_github.sh 保持一致的默认路径
BACKUP_REPO_DIR=${BACKUP_REPO_DIR:-/home/user/.astrbot-backup}
HIST_DIR=${HIST_DIR:-$BACKUP_REPO_DIR}
BACKUP_WAIT_TIMEOUT=${BACKUP_WAIT_TIMEOUT:-0}  # 0 表示无限等待

log() {
  echo "[waiter] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

wait_for_ready() {
  local script="/home/user/scripts/backup_to_github.sh"
  if [[ ! -x "$script" ]]; then
    log "未找到等待脚本：$script，跳过等待"
    return 0
  fi
  log "等待备份初始化完成（仓库/指针/大文件）... 超时: ${BACKUP_WAIT_TIMEOUT}s (0=不超时)"
  if command -v timeout >/dev/null 2>&1 && (( BACKUP_WAIT_TIMEOUT > 0 )); then
    if timeout --preserve-status "${BACKUP_WAIT_TIMEOUT}s" "$script" wait; then
      log "备份初始化完成，继续启动"
      return 0
    else
      log "等待超时(${BACKUP_WAIT_TIMEOUT}s)，继续启动"
      return 0
    fi
  else
    "$script" wait
    log "备份初始化完成，继续启动"
  fi
}

wait_for_ready

