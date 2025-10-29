#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# 参考 参考文件/launch.sh 重构：AstrBot/Napcat 数据与配置“历史仓库（history repo）”备份/还原器
# 特性：
# - 将目标路径迁移到统一的 Git 历史仓库（HIST_DIR），原路径创建符号链接，避免容器重启数据丢失
# - 每次循环：优先拉取 -> 指针化大文件(Release 资产) -> 下载指针文件指向的大文件 -> 提交/推送
# - 首次启动阻塞到数据“就绪”（指针文件均已下载），再通过 READINESS_FILE 放行其它进程
# - 3 分钟为默认轮询间隔，可通过 BACKUP_INTERVAL_SECONDS 调整

set -Eeuo pipefail

LANG=${LANG:-C.UTF-8}
export LANG

# ====== 模式与基础路径 ======
MODE=${1:-daemon}        # 支持：init|daemon|monitor|restore
BASE=${BASE:-/}          # 作为相对根目录，统一用绝对路径的相对形式

# 与旧脚本兼容：默认把历史仓库放在 BACKUP_REPO_DIR
BACKUP_REPO_DIR=${BACKUP_REPO_DIR:-/home/user/.astrbot-backup}
DATA_ROOT=${DATA_ROOT:-$BACKUP_REPO_DIR}
HIST_DIR=${HIST_DIR:-$BACKUP_REPO_DIR}

# 轮询与阈值
BACKUP_INTERVAL_SECONDS=${BACKUP_INTERVAL_SECONDS:-180}
LARGE_THRESHOLD=${LARGE_THRESHOLD:-52428800} # 50MB
SCAN_INTERVAL_SECS=${SCAN_INTERVAL_SECS:-$BACKUP_INTERVAL_SECONDS}

# Git 基本参数
GIT_BRANCH=${GIT_BRANCH:-main}
GIT_USER_NAME=${GIT_USER_NAME:-astrbot-backup}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-astrbot-backup@local}
GIT_OP_TIMEOUT=${GIT_OP_TIMEOUT:-25}

# GitHub（兼容环境变量）：
# 传入任一组即可：
# - GITHUB_USER + GITHUB_PAT + GITHUB_REPO(owner/repo)
# - 或 github_project(owner/repo) + github_secret(token)
GITHUB_USER=${GITHUB_USER:-}
GITHUB_PAT=${GITHUB_PAT:-}
GITHUB_REPO=${GITHUB_REPO:-}
github_project=${github_project:-${GITHUB_REPO:-}}
github_secret=${github_secret:-${GITHUB_PAT:-}}

# Release 资产（大文件指针化）
RELEASE_TAG=${RELEASE_TAG:-blobs}
KEEP_OLD_ASSETS=${KEEP_OLD_ASSETS:-false}
STICKY_POINTER=${STICKY_POINTER:-true}
VERIFY_SHA=${VERIFY_SHA:-true}
DOWNLOAD_RETRY=${DOWNLOAD_RETRY:-3}
HYDRATE_CHECK_INTERVAL=${HYDRATE_CHECK_INTERVAL:-3}
HYDRATE_TIMEOUT=${HYDRATE_TIMEOUT:-0}

# 就绪与健康
READINESS_FILE=${READINESS_FILE:-$HIST_DIR/.backup.ready}
# 日志目录（按需写入文件，并同时保留到标准输出）
SYNC_LOG_DIR=${SYNC_LOG_DIR:-/home/user/synclogs}

# 备份/管理的目标（相对 BASE）
TARGETS=${TARGETS:-"home/user/AstrBot/data home/user/config app/napcat/config home/user/nginx/admin_config.json app/.config/QQ home/user/gemini-data home/user/gemini-balance-main/.env"}

# ====== 日志与信号 ======
LOG() { printf '[%s] [backup] %s\n' "$(date '+%F %T')" "$*"; }
ERR() { printf '[%s] [backup] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

init_logging() {
  mkdir -p "$SYNC_LOG_DIR" >/dev/null 2>&1 || true
  local out="$SYNC_LOG_DIR/backup.log" err="$SYNC_LOG_DIR/backup.err"
  if command -v stdbuf >/dev/null 2>&1; then
    exec > >(stdbuf -oL tee -a "$out") 2> >(stdbuf -oL tee -a "$err" >&2)
  else
    exec > >(tee -a "$out") 2> >(tee -a "$err" >&2)
  fi
}

STOP_REQUESTED=0
on_term() { STOP_REQUESTED=1; LOG "收到停止信号，准备优雅退出"; }
trap on_term INT TERM

trap 'code=$?; if { [ "$MODE" = "init" ] || [ "$MODE" = "daemon" ] || [ "$MODE" = "monitor" ]; } && [ $code -ne 0 ]; then ERR "backup_to_github.sh 异常退出（$code）"; fi' EXIT

# 初始化日志重定向（必须尽早）
init_logging

# ====== 工具 ======
need_cmd() { command -v "$1" >/dev/null 2>&1; }
run_to() { local t=$1; shift || true; if need_cmd timeout; then timeout --preserve-status "$t" "$@"; else "$@"; fi; }
urlencode() { local s="$1" o="" c; for ((i=0;i<${#s};i++)); do c=${s:$i:1}; case "$c" in [a-zA-Z0-9._~-]) o+="$c";; ' ') o+="%20";; *) printf -v h '%02X' "'$c"; o+="%$h";; esac; done; printf '%s' "$o"; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
file_size() { local f="$1"; [ -f "$f" ] || { echo 0; return 1; }; if stat -c %s "$f" >/dev/null 2>&1; then stat -c %s "$f"; return 0; fi; if stat -f %z "$f" >/dev/null 2>&1; then stat -f %z "$f"; return 0; fi; wc -c < "$f" | tr -d ' '; }
now_ts() { date +%s; }

# ====== Git 仓库 ======
git_cfg() {
  git -C "$HIST_DIR" config user.name "$GIT_USER_NAME" || true
  git -C "$HIST_DIR" config user.email "$GIT_USER_EMAIL" || true
  git -C "$HIST_DIR" config pull.rebase true || true
  git config --global --add safe.directory "$HIST_DIR" >/dev/null 2>&1 || true
}

remote_url() {
  # 优先使用 GITHUB_USER/GITHUB_PAT/GITHUB_REPO；否则兼容 github_project/github_secret
  if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_PAT" ] && [ -n "$GITHUB_REPO" ]; then
    printf 'https://%s:%s@github.com/%s.git' "$GITHUB_USER" "$GITHUB_PAT" "$GITHUB_REPO"
  elif [ -n "$github_project" ] && [ -n "$github_secret" ]; then
    printf 'https://x-access-token:%s@github.com/%s.git' "$github_secret" "$github_project"
  else
    echo ""; return 1
  fi
}

ensure_repo() {
  mkdir -p "$HIST_DIR"
  if [ ! -d "$HIST_DIR/.git" ]; then
    LOG "初始化历史仓库：$HIST_DIR"
    git -C "$HIST_DIR" init -b "$GIT_BRANCH"
  fi
  git_cfg

  local url; url="$(remote_url || true)" || true
  if [ -n "$url" ]; then
    LOG "设置远端：repo=${github_project:-$GITHUB_REPO} branch=$GIT_BRANCH"
    if git -C "$HIST_DIR" remote | grep -q '^origin$'; then
      git -C "$HIST_DIR" remote set-url origin "$url"
    else
      git -C "$HIST_DIR" remote add origin "$url"
    fi
    run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" fetch --depth=1 origin "$GIT_BRANCH" || true
    git -C "$HIST_DIR" checkout -B "$GIT_BRANCH" || true
    run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" pull --depth=1 --rebase --autostash origin "$GIT_BRANCH" || true
  else
    LOG "未配置远端（GITHUB_* 或 github_*），将仅使用本地历史仓库"
    git -C "$HIST_DIR" checkout -B "$GIT_BRANCH" || true
  fi
}

git_sanitize_repo() {
  git -C "$HIST_DIR" rebase --abort >/dev/null 2>&1 || true
  git -C "$HIST_DIR" merge --abort >/dev/null 2>&1 || true
  git -C "$HIST_DIR" cherry-pick --abort >/dev/null 2>&1 || true
  rm -rf "$HIST_DIR/.git/rebase-merge" "$HIST_DIR/.git/REBASE_HEAD" "$HIST_DIR/.git/REBASE_APPLY" >/dev/null 2>&1 || true
}

# ====== 目标迁移与链接 ======
ensure_gitignore_entry() { local rel="$1"; local gi="$HIST_DIR/.gitignore"; touch "$gi"; grep -Fxq -- "$rel" "$gi" || echo "$rel" >> "$gi"; }

link_targets() {
  for target in $TARGETS; do
    local src dst
    src="${BASE%/}/$target"
    dst="${HIST_DIR%/}/$target"
    mkdir -p "$(dirname "$dst")"

    if [ -e "$src" ] && [ ! -L "$src" ]; then
      LOG "初始化目标：$target"
      if [ -d "$src" ]; then
        if need_cmd rsync; then rsync -av --ignore-existing "$src/" "$dst/" || cp -anr "$src/." "$dst/";
        else cp -anr "$src/." "$dst/"; fi
        rm -rf "$src"
      else
        if [ ! -e "$dst" ]; then mv -f "$src" "$dst"; else rm -f "$src"; fi
      fi
    fi

    if [ -e "$dst" ]; then
      if [ -L "$src" ]; then
        ln -sfn "$dst" "$src" 2>/dev/null || true
      elif [ ! -e "$src" ]; then
        mkdir -p "$(dirname "$src")" 2>/dev/null || true
        ln -s "$dst" "$src" 2>/dev/null || true
      fi
    fi
  done
}

process_target() {
  local t="$1" src dst
  src="${BASE%/}/$t"; dst="${HIST_DIR%/}/$t"
  if [ -e "$src" ] && [ ! -L "$src" ]; then
    LOG "发现新增：$t"
    mkdir -p "$(dirname "$dst")"; mv -f "$src" "$dst"; ln -s "$dst" "$src"
  fi
}

# ====== Release 资产与指针 ======
gh_api() {
  local method="$1" url="$2"; shift 2
  local auth=()
  [ -n "$github_secret" ] && auth=(-H "Authorization: Bearer ${github_secret}") || auth=()
  curl -sS -X "$method" "${auth[@]}" -H "Accept: application/vnd.github+json" "$url" "$@"
}

gh_ensure_release() {
  [ -n "$github_project" ] || return 1
  local api="https://api.github.com" tmp; tmp="$(mktemp)"
  local code; code="$(curl -sS -o "$tmp" -w '%{http_code}' ${github_secret:+-H "Authorization: Bearer ${github_secret}"} -H "Accept: application/vnd.github+json" "$api/repos/$github_project/releases/tags/$RELEASE_TAG")"
  if [ "$code" = "200" ]; then jq -r '.id // empty' "$tmp"; rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  local payload; payload="$(jq -nc --arg tag "$RELEASE_TAG" --arg name "$RELEASE_TAG" '{tag_name:$tag,name:$name,target_commitish:"main",draft:false,prerelease:false}')"
  gh_api POST "$api/repos/$github_project/releases" -H "Content-Type: application/json" -d "$payload" | jq -r '.id // empty'
}

gh_find_asset_id() {
  local rid="$1" name="$2"
  [ -n "$rid" ] || return 1
  local api="https://api.github.com"; gh_api GET "$api/repos/$github_project/releases/$rid/assets" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1
}

gh_upload_asset() {
  local rid="$1" file="$2" name="$3"
  [ -n "$rid" ] || return 1
  curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Content-Type: application/octet-stream" --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${rid}/assets?name=$(urlencode "$name")"
}

pointer_path_for() { local f="$1"; echo "$f.pointer"; }

pointerize_large_files() {
  [ -n "$github_project" ] && [ -n "$github_secret" ] || { LOG "未配置 github_project/github_secret，跳过大文件指针化"; return 0; }
  local rid; rid="$(gh_ensure_release || true)" || rid=""
  [ -n "$rid" ] || { ERR "无法确保 Release：$RELEASE_TAG"; return 1; }

  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    [ -e "$root" ] || continue
    if [ -d "$root" ]; then
      find "$root" -type f -not -name '*.pointer' -not -path '*/.git/*' -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            local sz sha base name aid ptr rel_rel
            sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
            sha="$(sha256_of "$f")"; base="$(basename "$f")"; name="${sha}-${base}"
            rel_rel="${f#${HIST_DIR%/}/}"; ptr="$(pointer_path_for "$f")"
            ensure_gitignore_entry "$rel_rel"
            aid="$(gh_find_asset_id "$rid" "$name" || true)"
            if [ -z "$aid" ]; then
              LOG "上传大文件到 Release: $rel_rel ($sz bytes)"
              gh_upload_asset "$rid" "$f" "$name" >/dev/null 2>&1 || true
              aid="$(gh_find_asset_id "$rid" "$name" || true)"
            fi
            local url="https://github.com/${github_project}/releases/download/${RELEASE_TAG}/$(urlencode "$name")"
            jq -nc \
              --arg repo "$github_project" \
              --arg tag "$RELEASE_TAG" \
              --arg asset "$name" \
              --arg asset_id "${aid:-}" \
              --arg url "$url" \
              --arg path "$rel_rel" \
              --arg size "$sz" \
              --arg sha "$sha" '{
                type:"release-asset", repo:$repo, release_tag:$tag,
                asset_name:$asset, asset_id:( ($asset_id|tonumber?) // null ),
                download_url:$url, original_path:$path,
                size:(($size|tonumber?) // 0), sha256:$sha, generated_at:(now|todate)
              }' > "$ptr"
            git -C "$HIST_DIR" add -f "$ptr" || true
            if [ "$STICKY_POINTER" = "true" ]; then
              rm -f "$f"
            fi
          done
    elif [ -f "$root" ]; then
      local f="$root" sz sha base name aid ptr rel_rel
      sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
      sha="$(sha256_of "$f")"; base="$(basename "$f")"; name="${sha}-${base}"
      rel_rel="${f#${HIST_DIR%/}/}"; ptr="$(pointer_path_for "$f")"
      ensure_gitignore_entry "$rel_rel"
      aid="$(gh_find_asset_id "$rid" "$name" || true)"
      if [ -z "$aid" ]; then
        LOG "上传大文件到 Release: $rel_rel ($sz bytes)"
        gh_upload_asset "$rid" "$f" "$name" >/dev/null 2>&1 || true
        aid="$(gh_find_asset_id "$rid" "$name" || true)"
      fi
      local url="https://github.com/${github_project}/releases/download/${RELEASE_TAG}/$(urlencode "$name")"
      jq -nc --arg repo "$github_project" --arg tag "$RELEASE_TAG" --arg asset "$name" --arg asset_id "${aid:-}" --arg url "$url" --arg path "$rel_rel" --arg size "$sz" --arg sha "$sha" '{
        type:"release-asset", repo:$repo, release_tag:$tag, asset_name:$asset,
        asset_id:( ($asset_id|tonumber?) // null ), download_url:$url, original_path:$path, size:(($size|tonumber?) // 0), sha256:$sha, generated_at:(now|todate)
      }' > "$ptr"
      git -C "$HIST_DIR" add -f "$ptr" || true
      if [ "$STICKY_POINTER" = "true" ]; then rm -f "$f"; fi
    fi
  done
}

try_curl_download() {
  local url="$1"; shift; local outfile="$3"; local allow_retry="$4"; shift 2
  local headers=("$@")
  local attempt=1
  while :; do
    if curl -fsSL -o "$outfile" "${headers[@]}" "$url"; then return 0; fi
    [ "$allow_retry" = "false" ] && return 1
    [ $attempt -ge $DOWNLOAD_RETRY ] && return 1
    sleep 1; attempt=$((attempt+1))
  done
}

hydrate_one_pointer() {
  local ptr="$1"
  local rel path repo tag name url size sha aid dst tmp
  rel="$(jq -r '.original_path // empty' "$ptr" 2>/dev/null || echo "")"; [ -n "$rel" ] || return 1
  path="${HIST_DIR%/}/$rel"; repo="$(jq -r '.repo // empty' "$ptr" 2>/dev/null || echo "")"
  tag="$(jq -r '.release_tag // "blobs"' "$ptr" 2>/dev/null)"
  name="$(jq -r '.asset_name // empty' "$ptr" 2>/dev/null || echo "")"
  url="$(jq -r '.download_url // empty' "$ptr" 2>/dev/null || echo "")"
  size="$(jq -r '.size // 0' "$ptr" 2>/dev/null || echo 0)"
  sha="$(jq -r '.sha256 // empty' "$ptr" 2>/dev/null || echo "")"
  aid="$(jq -r '.asset_id // empty' "$ptr" 2>/dev/null || echo "")"
  [ -n "$repo" ] || repo="$github_project"
  [ -n "$repo" ] || { ERR "指针缺少 repo：$ptr"; return 1; }
  mkdir -p "$(dirname "$path")"
  dst="$path"; tmp="$(mktemp)"

  local headers=()
  [ -n "$github_secret" ] && headers=(-H "Authorization: Bearer ${github_secret}")
  if [ -n "$aid" ]; then
    local api="https://api.github.com/repos/${repo}/releases/assets/${aid}"
    if ! try_curl_download "$api" "${headers[@]}" "$tmp" true -H "Accept: application/octet-stream"; then
      ERR "下载 asset_id 失败：$rel"
      rm -f "$tmp"; return 1
    fi
  elif [ -n "$url" ]; then
    if ! try_curl_download "$url" "${headers[@]}" "$tmp" true; then
      ERR "下载 URL 失败：$rel"; rm -f "$tmp"; return 1
    fi
  else
    local res aid2 url2 size2 sha2
    res="$(gh_api GET "https://api.github.com/repos/${repo}/releases/tags/${tag}")" || true
    aid2="$(echo "$res" | jq -r --arg n "$name" '.assets // [] | map(select(.name==$n)) | .[-1].id // empty' 2>/dev/null || echo "")"
    url2="$(echo "$res" | jq -r --arg n "$name" '.assets // [] | map(select(.name==$n)) | .[-1].browser_download_url // empty' 2>/dev/null || echo "")"
    size2="$(echo "$res" | jq -r --arg n "$name" '.assets // [] | map(select(.name==$n)) | .[-1].size // 0' 2>/dev/null || echo 0)"
    sha2="$(echo "$res" | jq -r --arg n "$name" '.assets // [] | map(select(.name==$n)) | .[-1].label // empty' 2>/dev/null || echo "")"
    local url_for_dl="$url2"; local headers2=()
    [ -n "$github_secret" ] && headers2=(-H "Authorization: Bearer ${github_secret}")
    if [ -n "$aid2" ]; then
      url_for_dl="https://api.github.com/repos/${repo}/releases/assets/${aid2}"; headers2=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
    fi
    if ! try_curl_download "$url_for_dl" "${headers2[@]}" "$tmp" true; then rm -f "$tmp"; return 1; fi
    [ -n "$size" ] || size="$size2"; [ -n "$sha" ] || sha="$sha2"
  fi

  local got_sz; got_sz="$(file_size "$tmp" || echo 0)"
  if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_sz" != "$size" ]; then ERR "大小不匹配：$rel"; rm -f "$tmp"; return 1; fi
  if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then
    local got_sha; got_sha="$(sha256_of "$tmp")"; [ "$got_sha" = "$sha" ] || { ERR "SHA 不匹配：$rel"; rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$dst"; chmod 0644 "$dst" || true
}

hydrate_from_pointers() {
  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    if [ -d "$root" ]; then
      find "$root" -type f -name '*.pointer' -print0 2>/dev/null | while IFS= read -r -d '' p; do hydrate_one_pointer "$p" || true; done
    elif [ -f "${root}.pointer" ]; then
      hydrate_one_pointer "${root}.pointer" || true
    fi
  done
}

all_pointers_hydrated() {
  local total=0 ok=0
  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    if [ -d "$root" ]; then
      while IFS= read -r -d '' p; do
        total=$((total+1))
        local rel dst size sha
        rel="$(jq -r '.original_path // empty' "$p" 2>/dev/null || echo "")"; dst="${HIST_DIR%/}/$rel"
        size="$(jq -r '.size // 0' "$p" 2>/dev/null || echo 0)"; sha="$(jq -r '.sha256 // empty' "$p" 2>/dev/null || echo "")"
        if [ -f "$dst" ]; then
          local cs; cs="$(file_size "$dst" || echo 0)"
          if [ "$cs" = "$size" ]; then
            if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then local csha; csha="$(sha256_of "$dst")"; [ "$csha" = "$sha" ] && ok=$((ok+1)); else ok=$((ok+1)); fi
          fi
        fi
      done < <(find "$root" -type f -name '*.pointer' -print0 2>/dev/null)
    elif [ -f "${root}.pointer" ]; then
      total=$((total+1))
      local p="${root}.pointer" rel dst size sha
      rel="$(jq -r '.original_path // empty' "$p" 2>/dev/null || echo "")"; dst="${HIST_DIR%/}/$rel"; size="$(jq -r '.size // 0' "$p" 2>/dev/null || echo 0)"; sha="$(jq -r '.sha256 // empty' "$p" 2>/dev/null || echo "")"
      if [ -f "$dst" ]; then
        local cs; cs="$(file_size "$dst" || echo 0)"
        if [ "$cs" = "$size" ]; then if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then local csha; csha="$(sha256_of "$dst")"; [ "$csha" = "$sha" ] && ok=$((ok+1)); else ok=$((ok+1)); fi; fi
      fi
    fi
  done
  echo "$ok/$total"; [ "$ok" -eq "$total" ]
}

wait_until_hydrated() {
  LOG "等待指针文件下载完成..."
  local start_ts; start_ts="$(now_ts)"
  while true; do
    hydrate_from_pointers
    local prog; prog="$(all_pointers_hydrated || true)"
    if all_pointers_hydrated >/dev/null 2>&1; then LOG "数据就绪：$prog"; break; else LOG "进度：$prog，继续等待..."; fi
    if [ "$HYDRATE_TIMEOUT" != "0" ]; then local elapsed=$(( $(now_ts) - start_ts )); [ "$elapsed" -ge "$HYDRATE_TIMEOUT" ] && { ERR "等待超时（$HYDRATE_TIMEOUT s）"; return 1; }; fi
    sleep "$HYDRATE_CHECK_INTERVAL"
  done
}

# ====== 提交与推送 ======
commit_and_push() {
  git_sanitize_repo
  git -C "$HIST_DIR" add -A
  if git -C "$HIST_DIR" diff --cached --quiet; then
    LOG "工作区无变更，跳过提交"
  else
    git -C "$HIST_DIR" commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')"
    LOG "已提交变更"
  fi
  if git -C "$HIST_DIR" remote | grep -q '^origin$'; then
    local pushed=0; for attempt in 1 2 3; do
      run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" fetch --depth=1 origin "$GIT_BRANCH" || true
      if ! run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" pull --depth=1 --rebase --autostash origin "$GIT_BRANCH"; then
        git -C "$HIST_DIR" rebase --abort >/dev/null 2>&1 || true
        LOG "pull --rebase 失败（第${attempt}次），重试"
      fi
      if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" push -u origin "$GIT_BRANCH"; then LOG "推送成功（第${attempt}次）"; pushed=1; break; else LOG "push 失败/被拒绝，重试(${attempt})"; sleep 1; fi
    done
    [ "$pushed" = 1 ] || ERR "多次重试仍无法推送，已保留本地提交"
  fi
}

# ====== 主流程 ======
mark_ready() { mkdir -p "$(dirname "$READINESS_FILE")"; : > "$READINESS_FILE"; }
healthbeat() { : > "$HIST_DIR/.backup.alive"; }

do_init() {
  ensure_repo
  link_targets
  pointerize_large_files || true
  commit_and_push || true
  wait_until_hydrated || true
  chmod -R 777 "$HIST_DIR" || true
  mark_ready
  LOG "初始化完成，已写入就绪文件：$READINESS_FILE"
}

start_monitor() {
  LOG "进入守护循环：每 ${SCAN_INTERVAL_SECS}s 扫描/同步一次"
  while true; do
    for t in $TARGETS; do process_target "$t"; done
    pointerize_large_files || true
    hydrate_from_pointers || true
    commit_and_push || true
    healthbeat
    [ $STOP_REQUESTED -eq 1 ] && { LOG "检测到停止请求，退出守护循环"; return 0; }
    local waited=0; while [ $waited -lt $SCAN_INTERVAL_SECS ]; do [ $STOP_REQUESTED -eq 1 ] && break; sleep 1; waited=$((waited+1)); done
    [ $STOP_REQUESTED -eq 1 ] && break
  done
}

case "$MODE" in
  init)
    do_init ;;
  daemon)
    do_init
    start_monitor ;;
  monitor)
    start_monitor ;;
  restore)
    ensure_repo; hydrate_from_pointers; mark_ready ;;
  *)
    ERR "未知模式：$MODE（应为 init|daemon|monitor|restore）"; exit 2 ;;
esac
