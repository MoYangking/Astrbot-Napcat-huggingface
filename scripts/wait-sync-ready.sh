#!/usr/bin/env bash
# Wait until sync daemon has fully pulled and linked
# Conditions:
#  1) HIST_DIR is a valid git repo with origin set
#  2) local HEAD equals origin/<branch>
#  3) All targets have been symlinked at BASE (best effort)

set -Euo pipefail

BASE=${BASE:-/}
HIST_DIR=${HIST_DIR:-/home/user/.astrbot-backup}
BRANCH=${GIT_BRANCH:-main}
declare -a TARGETS=()

DEFAULT_TARGETS=(
  home/user/AstrBot/data/
  home/user/config/
  app/napcat/config/
  home/user/nginx/admin_config.json
  app/.config/QQ/
  home/user/gemini-data/
  home/user/gemini-balance-main/.env
)

log() { printf '[%s] [wait-sync] %s\n' "$(date '+%F %T')" "$*"; }

abs_path() {
  local rel="$1"
  if [[ "$rel" = /* ]]; then printf '%s' "$rel"; return; fi
  if [[ "$BASE" = "/" ]]; then printf '/%s' "$rel"; else printf '%s/%s' "$BASE" "$rel"; fi
}

load_targets() {
  local cfg="$HIST_DIR/sync-config.json"
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    mapfile -t TARGETS < <(jq -r 'try .targets[] // empty' "$cfg" 2>/dev/null | sed 's#^/##') || true
  fi
  if (( ${#TARGETS[@]} == 0 )); then
    TARGETS=("${DEFAULT_TARGETS[@]}")
  fi
}

targets_symlinked() {
  local ok=0
  for rel in "${TARGETS[@]}"; do
    # Remove trailing slash for symlink check
    local rel_clean="${rel%/}"
    local p; p="$(abs_path "$rel_clean")"
    if [[ ! -L "$p" ]]; then 
      ok=1
    fi
  done
  return $ok
}

head_equals_remote() {
  git -C "$HIST_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$HIST_DIR" rev-parse "origin/$BRANCH" >/dev/null 2>&1 || return 1
  local h1 h2
  h1=$(git -C "$HIST_DIR" rev-parse HEAD 2>/dev/null || echo "")
  h2=$(git -C "$HIST_DIR" rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
  [[ -n "$h1" && "$h1" = "$h2" ]]
}

load_targets

log "等待同步完成：HIST_DIR=$HIST_DIR BRANCH=$BRANCH 目标数=${#TARGETS[@]}"
until head_equals_remote; do
  sleep 1
done
log "Git 已对齐远端 HEAD"

# 链接检查（容忍失败，仅用于尽量确保链接完成）
for i in {1..1000}; do
  targets_symlinked
  result=$?
  log "第 $i 次检查: targets_symlinked 返回值=$result"
  if [[ $result -eq 0 ]]; then
    log "目标符号链接已就绪"
    exit 0
  fi
  # 输出当前状态
  for rel in "${TARGETS[@]}"; do
    rel_clean="${rel%/}"
    p="$(abs_path "$rel_clean")"
    if [[ -L "$p" ]]; then
      log "  ✓ $p"
    else
      log "  ✗ $p"
    fi
  done
  sleep 1
done
log "符号链接未全部就绪，先继续启动（守护进程稍后会完成）"
exit 0
