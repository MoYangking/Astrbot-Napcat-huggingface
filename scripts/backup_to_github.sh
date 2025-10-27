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

# 需要备份的路径（支持绝对或相对“/”的形式，未以“/”开头的会被视为从根开始）
BACKUP_PATHS=(
  "home/user/AstrBot/data"
  "home/user/config"
  "app/napcat/config"
  "home/user/nginx/admin_config.json"
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_git() {
  if ! need_cmd git; then
    log "未找到 git，可在镜像/Dockerfile 中安装 git 后再使用。"
    die "缺少 git"
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
  if git ls-remote --exit-code --heads origin "$GIT_BRANCH" >/dev/null 2>&1; then
    log "检测到远端分支，拉取 origin/$GIT_BRANCH"
    git fetch --quiet origin "$GIT_BRANCH"
    git checkout -B "$GIT_BRANCH" "origin/$GIT_BRANCH"
  else
    log "远端分支不存在，将在首次备份时创建并推送 $GIT_BRANCH"
    git checkout -B "$GIT_BRANCH" || true
  fi
}

pull_remote_first() {
  # 尝试拉取远端更新，优先采用远端
  if git ls-remote --exit-code --heads origin "$GIT_BRANCH" >/dev/null 2>&1; then
    # 清理工作区，避免阻碍 rebase/pull
    git reset --hard || true
    git clean -fdx || true
    if ! git pull --rebase --no-edit origin "$GIT_BRANCH" >/dev/null 2>&1; then
      log "拉取远端失败，尝试硬重置到远端"
      git fetch --quiet origin "$GIT_BRANCH" || true
      git reset --hard "origin/$GIT_BRANCH" || true
    fi
  fi
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
  until git push origin "$GIT_BRANCH"; do
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

main_loop() {
  log "启动备份循环：每 ${BACKUP_INTERVAL_SECONDS}s 执行一次"
  while true; do
    if ! main_once; then
      log "本轮备份出现错误，但脚本将继续保活"
    fi
    sleep "$BACKUP_INTERVAL_SECONDS"
  done
}

init_until_ready() {
  log "进入初始化模式：等待首次同步成功后退出"
  while true; do
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
    # 首次成功后也可写一次就绪文件，便于后续新容器快速通过等待
    if main_once; then
      mark_ready
    fi
    main_loop ;;
  *)
    log "未知模式：$MODE，应为 init 或 daemon"; exit 2 ;;
esac
