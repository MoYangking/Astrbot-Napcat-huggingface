#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# AstrBot/Napcat 配置与数据备份脚本
# 功能：
# - 守护模式：每3分钟备份一次指定路径到 GitHub（远端优先）
# - 初始化模式：阻塞直至首次同步完成后退出（用于启动门闸）
# - 保活：守护模式内部循环 + 错误不中断；关键操作包含重试
# - 尽量减少依赖：优先使用 cp，rsync 存在则用 rsync

set -u -o pipefail

LANG=${LANG:-C.UTF-8}
export LANG

# ====== 配置（可通过环境变量覆盖）======
# GitHub 相关：
# - 必填：GITHUB_USER（你的 GitHub 用户名/组织成员身份），GITHUB_PAT（Personal access token classic），GITHUB_REPO（owner/repo 形式，如 user/my-backup）
# - 可选：GIT_BRANCH（默认 main）
# - 可选：BACKUP_REPO_DIR（本地备份仓库工作目录，默认 /home/user/.astrbot-backup）
# - 可选：BACKUP_INTERVAL_SECONDS（备份间隔秒，默认 180）
# - 可选：GIT_USER_NAME/GIT_USER_EMAIL（提交身份）
# - 可选：READINESS_FILE（初始化完成就绪文件，默认 $BACKUP_REPO_DIR/.backup.ready）
# 还原相关：
# - 可选：RESTORE_POLICY（never|on_empty|always，默认 on_empty）
# - 可选：RESTORE_STRATEGY（overlay|mirror，默认 overlay；mirror 会 --delete）
# - 可选：RESTORE_BACKUP_EXISTING（1|0，默认 1，把现有文件备份到 BACKUP_REPO_DIR/pre-restore）
# - 可选：RESTORE_ENFORCE_COUNT（>0 时，在首次就绪后重复叠加还原 N 次，默认 0 不启用）
# - 可选：RESTORE_ENFORCE_INTERVAL（叠加还原间隔秒，默认 5）

GITHUB_USER=${GITHUB_USER:-}
GITHUB_PAT=${GITHUB_PAT:-}
GITHUB_REPO=${GITHUB_REPO:-}
GIT_BRANCH=${GIT_BRANCH:-main}
BACKUP_REPO_DIR=${BACKUP_REPO_DIR:-/home/user/.astrbot-backup}
BACKUP_INTERVAL_SECONDS=${BACKUP_INTERVAL_SECONDS:-180}
GIT_USER_NAME=${GIT_USER_NAME:-astrbot-backup}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-astrbot-backup@local}
READINESS_FILE=${READINESS_FILE:-}
if [[ -z "$READINESS_FILE" ]]; then
  READINESS_FILE="$BACKUP_REPO_DIR/.backup.ready"
fi
GIT_OP_TIMEOUT=${GIT_OP_TIMEOUT:-25}
RESTORE_POLICY=${RESTORE_POLICY:-on_empty}
RESTORE_STRATEGY=${RESTORE_STRATEGY:-overlay}
RESTORE_BACKUP_EXISTING=${RESTORE_BACKUP_EXISTING:-1}
RESTORE_ENFORCE_COUNT=${RESTORE_ENFORCE_COUNT:-0}
RESTORE_ENFORCE_INTERVAL=${RESTORE_ENFORCE_INTERVAL:-5}

# 需要备份的路径（支持绝对或相对“/”的形式，未以“/”开头的会被视为从根开始）
BACKUP_PATHS=(
  "home/user/AstrBot/data"
  "home/user/config"
  "app/napcat/config"
  "home/user/nginx/admin_config.json"
  "app/napcat/.config/QQ"
)

# ====== 工具函数 ======
log() {
  # 避免打印 Token
  local msg="$*"
  msg="${msg//${GITHUB_PAT:-__NO_PAT__}/***}"  # 简单脱敏
  echo "[backup] $(date '+%Y-%m-%d %H:%M:%S') ${msg}" >&2
}

die() {
  log "错误：$*"
  exit 1
}

STOP_REQUESTED=0
on_term() {
  STOP_REQUESTED=1
  log "收到停止信号，请求优雅退出"
}
trap on_term INT TERM

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_git() {
  if ! need_cmd git; then
    log "未找到 git，可在镜像/Dockerfile 中安装 git 后再使用。"
    die "缺少 git"
  fi
}

run_with_timeout() {
  # 用法：run_with_timeout <秒> <cmd...>
  local t=$1; shift || true
  if need_cmd timeout; then
    timeout --preserve-status "$t" "$@"
  else
    "$@"
  fi
}

maybe_use_rsync() {
  if need_cmd rsync; then
    echo 1
  else
    echo 0
  fi
}

abs_path() {
  local p="$1"
  if [[ "$p" != /* ]]; then
    p="/$p"
  fi
  echo "$p"
}

has_data() {
  # 目录/文件是否“非空”
  local path="$1"
  if [[ -d "$path" ]]; then
    # 目录下是否有任何条目
    find "$path" -mindepth 1 -print -quit 2>/dev/null | grep -q .
  elif [[ -f "$path" ]]; then
    [[ -s "$path" ]]
  else
    return 1
  fi
}

# 复制 src -> dest（目录：全量覆盖；文件：就地覆盖）
copy_path() {
  local src="$1" dest="$2"
  if [[ -d "$src" ]]; then
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    if [[ "$(maybe_use_rsync)" == "1" ]]; then
      mkdir -p "$dest"
      rsync -a --delete "$src"/ "$dest"/
    else
      cp -a "$src" "$dest"
    fi
  elif [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
  else
    log "警告：路径不存在，跳过 -> $src"
  fi
}

git_cfg() {
  git config user.name "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
  git config pull.rebase true || true
}

remote_url() {
  if [[ -z "$GITHUB_USER" || -z "$GITHUB_PAT" || -z "$GITHUB_REPO" ]]; then
    die "必须提供环境变量：GITHUB_USER、GITHUB_PAT、GITHUB_REPO(例如 owner/repo)"
  fi
  echo "https://${GITHUB_USER}:${GITHUB_PAT}@github.com/${GITHUB_REPO}.git"
}

ensure_repo_ready() {
  mkdir -p "$BACKUP_REPO_DIR"
  cd "$BACKUP_REPO_DIR"

  if [[ ! -d .git ]]; then
    log "初始化本地备份仓库：$BACKUP_REPO_DIR"
    git init
    git symbolic-ref HEAD "refs/heads/${GIT_BRANCH}" || true
    git_cfg
    local url
    url="$(remote_url)"
    git remote add origin "$url"
  else
    git_cfg
    # 确保 origin 存在并指向当前 URL（避免重复添加）
    local url
    url="$(remote_url)"
    if git remote get-url origin >/dev/null 2>&1; then
      git remote set-url origin "$url"
    else
      git remote add origin "$url"
    fi
  fi

  # 如果远端已有分支，则检出远端分支；否则保持本地新分支，稍后首次提交时推送
  if run_with_timeout "$GIT_OP_TIMEOUT" git ls-remote --exit-code --heads origin "$GIT_BRANCH" >/dev/null 2>&1; then
    log "检测到远端分支，拉取 origin/$GIT_BRANCH"
    run_with_timeout "$GIT_OP_TIMEOUT" git fetch --quiet origin "$GIT_BRANCH" || true
    git checkout -B "$GIT_BRANCH" "origin/$GIT_BRANCH"
  else
    log "远端分支不存在，将在首次备份时创建并推送 $GIT_BRANCH"
    git checkout -B "$GIT_BRANCH" || true
  fi
}

pull_remote_first() {
  # 尝试拉取远端更新，优先采用远端
  if run_with_timeout "$GIT_OP_TIMEOUT" git ls-remote --exit-code --heads origin "$GIT_BRANCH" >/dev/null 2>&1; then
    # 清理工作区，避免阻碍 rebase/pull
    git reset --hard || true
    git clean -fdx || true
    if ! run_with_timeout "$GIT_OP_TIMEOUT" git pull --rebase --no-edit origin "$GIT_BRANCH" >/dev/null 2>&1; then
      log "拉取远端失败，尝试硬重置到远端"
      run_with_timeout "$GIT_OP_TIMEOUT" git fetch --quiet origin "$GIT_BRANCH" || true
      git reset --hard "origin/$GIT_BRANCH" || true
    fi
  fi
}

backup_existing_before_restore() {
  local dest="$1"
  local ts
  ts="$(date -u '+%Y%m%d-%H%M%S')"
  local backup_root="$BACKUP_REPO_DIR/pre-restore/$ts"
  local ap
  ap="$(abs_path "$dest")"
  local rel
  rel="${ap#/}"
  local target="$backup_root/$rel"
  mkdir -p "$(dirname "$target")"
  if [[ -d "$ap" ]]; then
    if [[ "$(maybe_use_rsync)" == "1" ]]; then
      rsync -a "$ap"/ "$target"/
    else
      cp -a "$ap" "$target"
    fi
  elif [[ -f "$ap" ]]; then
    cp -a "$ap" "$target"
  fi
}

restore_single() {
  local stage_src="$1" dest="$2"
  if [[ -d "$stage_src" ]]; then
    mkdir -p "$dest"
    if [[ "$(maybe_use_rsync)" == "1" ]]; then
      if [[ "$RESTORE_STRATEGY" == "mirror" ]]; then
        rsync -a --delete "$stage_src"/ "$dest"/
      else
        rsync -a "$stage_src"/ "$dest"/
      fi
    else
      # rsync 不可用时，目录的 mirror 比较难安全实现；退化为覆盖式复制
      if [[ "$RESTORE_STRATEGY" == "mirror" ]]; then
        rm -rf "$dest"/*
      fi
      cp -a "$stage_src"/. "$dest"/
    fi
  elif [[ -f "$stage_src" ]]; then
    mkdir -p "$(dirname "$dest")"
    if [[ "$RESTORE_STRATEGY" == "mirror" && -e "$dest" ]]; then
      rm -f "$dest"
    fi
    cp -a "$stage_src" "$dest"
  else
    log "还原跳过：快照中不存在 -> $stage_src"
  fi
}

restore_from_snapshot() {
  ensure_git
  ensure_repo_ready
  pull_remote_first
  local base="$BACKUP_REPO_DIR/stage"
  if [[ ! -d "$base" ]]; then
    log "未发现快照目录：$base，跳过还原"
    return 1
  fi

  local restored_any=0
  for p in "${BACKUP_PATHS[@]}"; do
    local ap stage_src
    ap="$(abs_path "$p")"
    stage_src="$base/${ap#/}"
    if [[ -e "$stage_src" ]]; then
      if (( RESTORE_BACKUP_EXISTING )); then
        if [[ -e "$ap" ]]; then
          backup_existing_before_restore "$ap" || true
        fi
      fi
      restore_single "$stage_src" "$ap"
      restored_any=1
      log "已还原：$ap"
    else
      log "快照缺失该路径，跳过：$ap"
    fi
  done

  if (( restored_any == 0 )); then
    log "快照存在但未还原任何路径（可能 BACKUP_PATHS 不匹配）"
    return 1
  fi
  return 0
}

maybe_restore() {
  case "$RESTORE_POLICY" in
    never)
      log "还原策略：never，跳过还原"; return 0 ;;
    always)
      log "还原策略：always，执行全量还原"; restore_from_snapshot; return $? ;;
    on_empty)
      log "还原策略：on_empty，仅对空目标进行还原"
      ensure_git; ensure_repo_ready; pull_remote_first
      local base="$BACKUP_REPO_DIR/stage"; [[ -d "$base" ]] || { log "无快照，跳过"; return 0; }
      local did=0
      for p in "${BACKUP_PATHS[@]}"; do
        local ap stage_src
        ap="$(abs_path "$p")"; stage_src="$base/${ap#/}"
        if [[ -e "$stage_src" ]]; then
          if ! has_data "$ap"; then
            (( RESTORE_BACKUP_EXISTING )) && [[ -e "$ap" ]] && backup_existing_before_restore "$ap" || true
            restore_single "$stage_src" "$ap" && did=1 && log "已按 on_empty 还原：$ap"
          else
            log "目标非空，按策略跳过：$ap"
          fi
        fi
      done
      (( did )) && return 0 || return 0 ;;
    *)
      log "未知 RESTORE_POLICY：$RESTORE_POLICY，按 never 处理"; return 0 ;;
  esac
}

make_snapshot() {
  # 将需要的路径复制进 stage/ 下，保留类似绝对路径结构
  mkdir -p stage
  # 清空旧快照
  rm -rf stage/* 2>/dev/null || true

  for p in "${BACKUP_PATHS[@]}"; do
    local ap
    ap="$(abs_path "$p")"
    local rel
    rel="${ap#/}"
    local dest
    dest="stage/$rel"
    copy_path "$ap" "$dest"
  done

  # 添加一个元信息文件便于排障
  mkdir -p stage/.backup_meta
  {
    echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "host=$(hostname || echo unknown)"
  } > stage/.backup_meta/info
}

COMMITTED=0
commit_if_changed() {
  git add -A stage
  if git diff --cached --quiet; then
    log "无变更，本轮无需提交"
    COMMITTED=0
    return 0
  fi
  local ts
  ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  git commit -m "Auto backup: ${ts}"
  COMMITTED=1
}

push_with_retry() {
  local tries=0 max=3
  until run_with_timeout "$GIT_OP_TIMEOUT" git push origin "$GIT_BRANCH"; do
    tries=$((tries+1))
    if (( tries >= max )); then
      log "推送失败(已重试 ${tries} 次)，放弃本轮"
      return 1
    fi
    log "推送失败，${tries} 秒后重试(${tries}/${max})"
    sleep "$tries"
    # 再次优先拉取，避免冲突
    pull_remote_first
    done
}

healthbeat() {
  : > "$BACKUP_REPO_DIR/.backup.alive"
}

mark_ready() {
  mkdir -p "$(dirname "$READINESS_FILE")"
  : > "$READINESS_FILE"
}

main_once() {
  ensure_git
  ensure_repo_ready
  pull_remote_first
  make_snapshot
  commit_if_changed || return 1
  if [[ "$COMMITTED" == "1" ]]; then
    push_with_retry || return 1
  fi
  healthbeat
}

sleep_interval() {
  local total=${1:-$BACKUP_INTERVAL_SECONDS}
  local i=0
  while (( i < total )); do
    (( STOP_REQUESTED )) && return 0
    sleep 1
    i=$((i+1))
  done
}

main_loop() {
  log "启动备份循环：每 ${BACKUP_INTERVAL_SECONDS}s 执行一次"
  while true; do
    if ! main_once; then
      log "本轮备份出现错误，但脚本将继续保活"
    fi
    (( STOP_REQUESTED )) && { log "检测到停止请求，退出守护循环"; return 0; }
    sleep_interval "$BACKUP_INTERVAL_SECONDS"
  done
}

init_until_ready() {
  log "进入初始化模式：等待首次同步成功后退出"
  # 初始化模式先执行一次按策略还原
  maybe_restore || true
  while true; do
    (( STOP_REQUESTED )) && { log "收到停止请求，初始化提前退出"; return 143; }
    if main_once; then
      mark_ready
      log "初始化同步完成，写入就绪文件：$READINESS_FILE"
      return 0
    fi
    log "初始化失败：等待重试"
    sleep 5
  done
}

trap 'log "收到停止信号，退出"; exit 0' INT TERM

MODE=${1:-daemon}
case "$MODE" in
  init)
    init_until_ready ;;
  daemon)
    # 首次循环前执行按策略还原，避免先把空目录上传到远端
    maybe_restore || true
    if main_once; then
      mark_ready
      # 如配置了还原加固窗口，则在就绪后重复叠加还原 N 次，降低服务首次启动时自写覆盖的风险
      if (( RESTORE_ENFORCE_COUNT > 0 )); then
        log "进入还原加固窗口：${RESTORE_ENFORCE_COUNT} 次，每次间隔 ${RESTORE_ENFORCE_INTERVAL}s"
        for ((i=1; i<=RESTORE_ENFORCE_COUNT; i++)); do
          (( STOP_REQUESTED )) && break
          maybe_restore || true
          sleep "$RESTORE_ENFORCE_INTERVAL"
        done
      fi
    fi
    main_loop ;;
  restore)
    # 单次还原并退出（不会进入备份循环）
    if restore_from_snapshot; then
      log "还原完成"
      exit 0
    else
      log "还原失败或无可还原内容"
      exit 1
    fi ;;
  *)
    log "未知模式：$MODE，应为 init 或 daemon"; exit 2 ;;
esac
