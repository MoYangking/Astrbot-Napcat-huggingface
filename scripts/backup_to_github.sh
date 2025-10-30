#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#
# backup_to_github.sh (fixed: commit on ANY change immediately)
#
# Key behavior:
# - Never delete local large files (ALWAYS_KEEP_LOCAL=true)
# - Transactional pointer update: only after upload success do we write/commit *.pointer
# - Releases keep only MAX_ASSET_VERSIONS (default=3) per base filename
# - Hydrate fallback: when current asset missing, fallback to previous asset
# - Pull once on init; afterwards DO NOT pull; monitor local changes and upload/commit immediately
# - Immediate commit on ANY change (large or small; create/move/modify/delete)
# - Optional AUTO_PUSH to push commits after each change
#
set -Eeuo pipefail

LANG=${LANG:-C.UTF-8}
export LANG

MODE=${1:-daemon}        # init|daemon|monitor|restore|wait
BASE=${BASE:-/}

BACKUP_REPO_DIR=${BACKUP_REPO_DIR:-/home/user/.astrbot-backup}
DATA_ROOT=${DATA_ROOT:-$BACKUP_REPO_DIR}
HIST_DIR=${HIST_DIR:-$BACKUP_REPO_DIR}

BACKUP_INTERVAL_SECONDS=${BACKUP_INTERVAL_SECONDS:-120}
LARGE_THRESHOLD=${LARGE_THRESHOLD:-52428800} # 50MB
SCAN_INTERVAL_SECS=${SCAN_INTERVAL_SECS:-$BACKUP_INTERVAL_SECONDS}

PULL_POLICY=${PULL_POLICY:-once}            # once|never
AUTO_PUSH=${AUTO_PUSH:-false}
ALWAYS_KEEP_LOCAL=${ALWAYS_KEEP_LOCAL:-true}
MAX_ASSET_VERSIONS=${MAX_ASSET_VERSIONS:-3}

GIT_BRANCH=${GIT_BRANCH:-main}
GIT_USER_NAME=${GIT_USER_NAME:-astrbot-backup}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-astrbot-backup@local}
GIT_OP_TIMEOUT=${GIT_OP_TIMEOUT:-25}
INIT_SYNC_TIMEOUT=${INIT_SYNC_TIMEOUT:-0}
INIT_SYNC_CHECK_INTERVAL=${INIT_SYNC_CHECK_INTERVAL:-3}

GITHUB_USER=${GITHUB_USER:-}
GITHUB_PAT=${GITHUB_PAT:-}
GITHUB_REPO=${GITHUB_REPO:-}
github_project=${github_project:-${GITHUB_REPO:-}}
github_secret=${github_secret:-${GITHUB_PAT:-}}

RELEASE_TAG=${RELEASE_TAG:-blobs}
VERIFY_SHA=${VERIFY_SHA:-true}
DOWNLOAD_RETRY=${DOWNLOAD_RETRY:-3}
HYDRATE_CHECK_INTERVAL=${HYDRATE_CHECK_INTERVAL:-3}
HYDRATE_TIMEOUT=${HYDRATE_TIMEOUT:-0}

READINESS_FILE=${READINESS_FILE:-$HIST_DIR/.backup.ready}
SYNC_LOG_DIR=${SYNC_LOG_DIR:-/home/user/synclogs}

TARGETS=${TARGETS:-"home/user/AstrBot/data home/user/config app/napcat/config home/user/nginx/admin_config.json app/.config/QQ home/user/gemini-data home/user/gemini-balance-main/.env"}
DIRLIKE_TARGETS=${DIRLIKE_TARGETS:-"home/user/AstrBot/data home/user/config app/napcat/config app/.config/QQ home/user/gemini-data"}
EXCLUDE_PATHS=${EXCLUDE_PATHS:-"home/user/AstrBot/data/plugin_data/jm_cosmos home/user/AstrBot/data/memes_data /home/user/AstrBot/data/temp"}

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
init_logging

STOP_REQUESTED=0
on_term() { STOP_REQUESTED=1; LOG "收到停止信号，准备优雅退出"; }
trap on_term INT TERM
trap 'code=$?; if { [ "$MODE" = "init" ] || [ "$MODE" = "daemon" ] || [ "$MODE" = "monitor" ]; } && [ $code -ne 0 ]; then ERR "backup_to_github.sh 异常退出（$code）"; fi' EXIT

need_cmd() { command -v "$1" >/dev/null 2>&1; }
run_to() { local t=$1; shift || true; if need_cmd timeout; then timeout --preserve-status "$t" "$@"; else "$@"; fi; }
urlencode() { local s="$1" o="" c; for ((i=0;i<${#s};i++)); do c=${s:$i:1}; case "$c" in [a-zA-Z0-9._~-]) o+="$c";; ' ') o+="%20";; *) printf -v h '%02X' "'$c"; o+="%$h";; esac; done; printf '%s' "$o"; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
file_size() { local f="$1"; [ -f "$f" ] || { echo 0; return 1; }; if stat -c %s "$f" >/dev/null 2>&1; then stat -c %s "$f"; return 0; fi; if stat -f %z "$f" >/dev/null 2>&1; then stat -f %z "$f"; return 0; fi; wc -c < "$f" | tr -d ' '; }
now_ts() { date +%s; }

# ==== exclude helpers ====
is_excluded_rel() {
  local rel="$1"; rel="${rel#./}"
  for ex in $EXCLUDE_PATHS; do
    ex="${ex#./}"
    case "$rel" in
      "$ex"|"$ex"/*) return 0 ;;
    esac
  done
  return 1
}

ensure_git_exclude_entry() {
  local rel="$1"; local exfile="$HIST_DIR/.git/info/exclude"
  mkdir -p "$(dirname "$exfile")" 2>/dev/null || true
  touch "$exfile"
  grep -Fxq -- "$rel" "$exfile" 2>/dev/null || echo "$rel" >> "$exfile"
}
apply_exclude_rules() { for ex in $EXCLUDE_PATHS; do ensure_git_exclude_entry "$ex"; done; }

# ==== git ====
git_cfg() {
  git -C "$HIST_DIR" config user.name "$GIT_USER_NAME" || true
  git -C "$HIST_DIR" config user.email "$GIT_USER_EMAIL" || true
  git -C "$HIST_DIR" config pull.rebase true || true
  git config --global --add safe.directory "$HIST_DIR" >/dev/null 2>&1 || true
}
remote_url() {
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
    if [ "$PULL_POLICY" = "once" ]; then
      local start_ts; start_ts="$(now_ts)"
      local target_branch="$GIT_BRANCH"
      while true; do
        if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" ls-remote --exit-code origin >/dev/null 2>&1; then
          if ! run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" ls-remote --exit-code --heads origin "$GIT_BRANCH" >/dev/null 2>&1; then
            local head_line head_ref
            head_line="$(run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" ls-remote --symref origin HEAD 2>/dev/null || true)"
            head_ref="$(printf '%s' "$head_line" | awk '/^ref:/{print $2}' | sed 's#refs/heads/##' 2>/dev/null || true)"
            [ -n "$head_ref" ] && target_branch="$head_ref" || target_branch="$GIT_BRANCH"
            LOG "远端未找到分支 '$GIT_BRANCH'，使用默认分支 '$target_branch'"
          fi
          if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" fetch --depth=1 origin "$target_branch"; then
            git -C "$HIST_DIR" checkout -B "$target_branch" || true
            if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" reset --hard "origin/$target_branch"; then
              LOG "首次拉取完成：origin/$target_branch"; GIT_BRANCH="$target_branch"; break
            fi
          fi
          LOG "拉取未完成，稍后重试（branch=$target_branch）..."
        else
          LOG "无法访问远端仓库，等待网络/凭据可用后重试..."
        fi
        if [ "$INIT_SYNC_TIMEOUT" != "0" ]; then
          local elapsed=$(( $(now_ts) - start_ts ))
          if [ "$elapsed" -ge "$INIT_SYNC_TIMEOUT" ]; then
            ERR "首次拉取等待超时(${INIT_SYNC_TIMEOUT}s)，继续初始化"
            break
          fi
        fi
        sleep "$INIT_SYNC_CHECK_INTERVAL"
      done
    else
      LOG "PULL_POLICY=never：跳过首次拉取"
      git -C "$HIST_DIR" checkout -B "$GIT_BRANCH" || true
    fi
  else
    LOG "未配置远端，使用本地仓库"
    git -C "$HIST_DIR" checkout -B "$GIT_BRANCH" || true
  fi
}
commit_local() {
  git -C "$HIST_DIR" add -A
  if git -C "$HIST_DIR" diff --cached --quiet; then
    LOG "工作区无变更，跳过提交"
    return 0
  fi
  git -C "$HIST_DIR" commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')"
  LOG "已提交变更（本地）"
  if [ "$AUTO_PUSH" = "true" ] && git -C "$HIST_DIR" remote | grep -q '^origin$'; then
    if ! run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" push -u origin "$GIT_BRANCH"; then
      ERR "push 失败/被拒绝，已保留本地提交"
    else
      LOG "push 成功"
    fi
  fi
}

ensure_gitignore_entry() { local rel="$1"; local gi="$HIST_DIR/.gitignore"; touch "$gi"; grep -Fxq -- "$rel" "$gi" || echo "$rel" >> "$gi"; }
ensure_gitattributes_entry() {
  local pattern="$1"; shift
  local attrs="$*"
  local gaf="$HIST_DIR/.gitattributes"
  mkdir -p "$(dirname "$gaf")" 2>/dev/null || true
  touch "$gaf"
  if ! grep -Fqx -- "$pattern $attrs" "$gaf" 2>/dev/null; then
    echo "$pattern $attrs" >> "$gaf"
  fi
  git -C "$HIST_DIR" add -f -- .gitattributes >/dev/null 2>&1 || true
}
ensure_pointer_merge_config() {
  git -C "$HIST_DIR" config merge.ours.driver true >/dev/null 2>&1 || true
  ensure_gitattributes_entry "*.pointer" "merge=ours"
}

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

# ==== GitHub Release & pointers ====
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
gh_list_assets_json() { local rid="$1"; [ -n "$rid" ] || return 1; gh_api GET "https://api.github.com/repos/$github_project/releases/$rid/assets"; }
gh_find_asset_id() { local rid="$1" name="$2"; [ -n "$rid" ] || return 1; gh_list_assets_json "$rid" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1; }
gh_delete_asset() {
  local asset_id="$1"; [ -n "$asset_id" ] || return 1
  local api="https://api.github.com/repos/${github_project}/releases/assets/${asset_id}"
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "$api")"
  if [ "$code" = "204" ]; then LOG "删除历史资产：id=$asset_id"; else ERR "删除历史资产失败：id=$asset_id code=$code"; fi
}
pointer_path_for() { local f="$1"; echo "$f.pointer"; }

write_pointer_after_confirm() {
  local rid="$1" f="$2" rel_rel="$3" size="$4" sha="$5"
  local base name aid url ptr
  base="$(basename "$f")"; name="${sha}-${base}"; ptr="$(pointer_path_for "$f")"
  aid="$(gh_find_asset_id "$rid" "$name" || true)"
  if [ -z "$aid" ]; then
    LOG "上传大文件到 Release: $rel_rel ($size bytes)"
    if ! gh_upload_asset "$rid" "$f" "$name" >/dev/null 2>&1; then
      ERR "上传失败：$rel_rel"; return 1
    fi
    aid="$(gh_find_asset_id "$rid" "$name" || true)"
    if [ -z "$aid" ]; then ERR "上传确认失败：$rel_rel"; return 1; fi
  fi
  url="https://github.com/${github_project}/releases/download/${RELEASE_TAG}/$(urlencode "$name")"
  if ! curl -sS -I ${github_secret:+-H "Authorization: Bearer ${github_secret}"} "$url" | head -n1 | grep -qE ' 200 | 302 '; then
    ERR "上传后资源不可用：$rel_rel ($url)"; return 1
  fi
  jq -nc \
    --arg repo "$github_project" \
    --arg tag "$RELEASE_TAG" \
    --arg asset "$name" \
    --arg asset_id "${aid:-}" \
    --arg url "$url" \
    --arg path "$rel_rel" \
    --arg size "$size" \
    --arg sha "$sha" '{
      type:"release-asset", repo:$repo, release_tag:$tag,
      asset_name:$asset, asset_id:( ($asset_id|tonumber?) // null ),
      download_url:$url, original_path:$path,
      size:(($size|tonumber?) // 0), sha256:$sha, generated_at:(now|todate)
    }' > "$ptr"
  git -C "$HIST_DIR" add -f "$ptr" || true
  enforce_asset_retention "$rid" "$base" "$MAX_ASSET_VERSIONS" "$name"
}

enforce_asset_retention() {
  local rid="$1" base="$2" keep="$3" current_name="$4"
  [ -n "$rid" ] || return 0
  local list; list="$(gh_list_assets_json "$rid" || echo '[]')"
  echo "$list" | jq -r --arg base "$base" --arg cur "$current_name" --argjson keep "$keep" '
    [ .[] | select(.name | test("^[0-9a-fA-F]{64}-" + ($base|gsub("\\W"; "\\\\$0")) + "$")) | {id:.id,name:.name} ]
    | sort_by(.id) as $all
    | if ($all|length) > $keep
      then ($all|.[0:(length - $keep)] | map(select(.name != $cur)) | .[].id)
      else empty
      end
  ' | while read -r old_id; do
    [ -n "$old_id" ] && gh_delete_asset "$old_id"
  done
}

gh_upload_asset() {
  local rid="$1" file="$2" name="$3"
  [ -n "$rid" ] || return 1
  curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Content-Type: application/octet-stream" --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${rid}/assets?name=$(urlencode "$name")"
}

pointerize_txn() {
  [ -n "$github_project" ] && [ -n "$github_secret" ] || { LOG "未配置 github_project/github_secret，跳过指针化"; return 0; }
  local rid; rid="$(gh_ensure_release || true)" || rid=""
  [ -n "$rid" ] || { ERR "无法确保 Release：$RELEASE_TAG"; return 1; }

  local only_path="${1:-}"
  if [ -n "$only_path" ]; then
    local f="$only_path"
    if [ -f "$f" ]; then
      local sz sha rel_rel
      sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || return 0
      sha="$(sha256_of "$f")"; rel_rel="${f#${HIST_DIR%/}/}"
      is_excluded_rel "$rel_rel" && return 0
      ensure_gitignore_entry "$rel_rel"
      write_pointer_after_confirm "$rid" "$f" "$rel_rel" "$sz" "$sha" || return 1
      commit_local || true
    fi
    return 0
  fi

  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    [ -e "$root" ] || continue
    if [ -d "$root" ]; then
      find "$root" -type f -not -name '*.pointer' -not -path '*/.git/*' -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            local sz sha rel_rel
            sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
            sha="$(sha256_of "$f")"; rel_rel="${f#${HIST_DIR%/}/}"
            is_excluded_rel "$rel_rel" && continue
            ensure_gitignore_entry "$rel_rel"
            write_pointer_after_confirm "$rid" "$f" "$rel_rel" "$sz" "$sha" || true
          done
    elif [ -f "$root" ]; then
      local f="$root" sz sha rel_rel
      sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
      sha="$(sha256_of "$f")"; rel_rel="${f#${HIST_DIR%/}/}"
      is_excluded_rel "$rel_rel" && continue
      ensure_gitignore_entry "$rel_rel"
      write_pointer_after_confirm "$rid" "$f" "$rel_rel" "$sz" "$sha" || true
    fi
  done
  commit_local || true
}

try_curl_download() {
  local url="$1"; shift
  local outfile="$1"; shift
  local allow_retry="$1"; shift
  local headers=("$@")
  local attempt=1
  while :; do
    if curl -fsSL -o "$outfile" "${headers[@]}" "$url"; then return 0; fi
    [ "$allow_retry" = "false" ] && return 1
    [ $attempt -ge $DOWNLOAD_RETRY ] && return 1
    sleep 1; attempt=$((attempt+1))
  done
}

download_previous_version() {
  local repo="$1" tag="$2" base="$3" cur_name="$4" out="$5"
  local res; res="$(gh_api GET "https://api.github.com/repos/${repo}/releases/tags/${tag}")" || true
  local prev_url prev_id
  prev_url="$(echo "$res" | jq -r --arg base "$base" --arg cur "$cur_name" '
    .assets // []
    | map(select(.name | test("^[0-9a-fA-F]{64}-" + ($base|gsub("\\W"; "\\\\$0")) + "$")))
    | sort_by(.id) as $arr
    | ($arr | map(.name) | index($cur)) as $idx
    | if ($idx != null and $idx > 0) then ($arr[$idx-1].browser_download_url // empty) else "" end
  ' 2>/dev/null || echo "")"
  prev_id="$(echo "$res" | jq -r --arg base "$base" --arg cur "$cur_name" '
    .assets // []
    | map(select(.name | test("^[0-9a-fA-F]{64}-" + ($base|gsub("\\W"; "\\\\$0")) + "$")))
    | sort_by(.id) as $arr
    | ($arr | map(.name) | index($cur)) as $idx
    | if ($idx != null and $idx > 0) then ($arr[$idx-1].id // empty) else "" end
  ' 2>/dev/null || echo "")"
  [ -z "$prev_url$prev_id" ] && return 1

  local headers2=()
  [ -n "$github_secret" ] && headers2=(-H "Authorization: Bearer ${github_secret}")
  if [ -n "$prev_id" ]; then
    local api="https://api.github.com/repos/${repo}/releases/assets/${prev_id}"
    headers2=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
    try_curl_download "$api" "$out" true "${headers2[@]}"
  else
    try_curl_download "$prev_url" "$out" true "${headers2[@]}"
  fi
}

hydrate_one_pointer() {
  local ptr="$1"
  local rel path repo tag name url size sha aid dst tmp base
  rel="$(jq -r '.original_path // empty' "$ptr" 2>/dev/null || echo "")"; [ -n "$rel" ] || return 1
  path="${HIST_DIR%/}/$rel"; repo="$(jq -r '.repo // empty' "$ptr" 2>/dev/null || echo "")"
  tag="$(jq -r '.release_tag // "blobs"' "$ptr" 2>/dev/null)"
  name="$(jq -r '.asset_name // empty' "$ptr" 2>/dev/null || echo "")"
  url="$(jq -r '.download_url // empty' "$ptr" 2>/dev/null || echo "")"
  size="$(jq -r '.size // 0' "$ptr" 2>/dev/null || echo 0)"
  sha="$(jq -r '.sha256 // empty' "$ptr" 2>/dev/null || echo "")"
  aid="$(jq -r '.asset_id // empty' "$ptr" 2>/dev/null || echo "")"
  base="$(basename "$name" | sed 's/^[0-9a-fA-F]\{64\}-//')" || base=""
  [ -n "$repo" ] || repo="$github_project"
  [ -n "$repo" ] || { ERR "指针缺少 repo：$ptr"; return 1; }
  mkdir -p "$(dirname "$path")"
  dst="$path"; tmp="$(mktemp)"

  local headers=()
  [ -n "$github_secret" ] && headers=(-H "Authorization: Bearer ${github_secret}")
  if is_excluded_rel "$rel"; then LOG "跳过黑名单指针：$rel"; return 0; fi

  local ok=0
  if [ -n "$aid" ]; then
    local api="https://api.github.com/repos/${repo}/releases/assets/${aid}"
    if try_curl_download "$api" "$tmp" true "${headers[@]}" -H "Accept: application/octet-stream"; then ok=1; fi
  elif [ -n "$url" ]; then
    if try_curl_download "$url" "$tmp" true "${headers[@]}"; then ok=1; fi
  fi

  if [ "$ok" != "1" ]; then
    LOG "当前版本下载失败，尝试回退到上一版本：$rel"
    if ! download_previous_version "$repo" "$tag" "$base" "$name" "$tmp"; then
      ERR "回退下载失败：$rel"; rm -f "$tmp"; return 1
    fi
    local got_sz; got_sz="$(file_size "$tmp" || echo 0)"
    LOG "已回退下载上一版本（$got_sz bytes）：$rel"
  else
    local got_sz; got_sz="$(file_size "$tmp" || echo 0)"
    if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_sz" != "$size" ]; then ERR "大小不匹配：$rel"; rm -f "$tmp"; return 1; fi
    if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then
      local got_sha; got_sha="$(sha256_of "$tmp")"; [ "$got_sha" = "$sha" ] || { ERR "SHA 不匹配：$rel"; rm -f "$tmp"; return 1; }
    fi
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

wait_until_hydrated() {
  LOG "等待指针文件下载完成..."
  local start_ts; start_ts="$(now_ts)"
  while true; do
    hydrate_from_pointers
    # 只要 hydrate 成功一次就退出（不做严格全量校验），以避免阻塞
    if [ -f "$READINESS_FILE" ]; then break; fi
    if [ "$HYDRATE_TIMEOUT" != "0" ]; then local elapsed=$(( $(now_ts) - start_ts )); [ "$elapsed" -ge "$HYDRATE_TIMEOUT" ] && { ERR "等待超时（$HYDRATE_TIMEOUT s）"; return 1; }; fi
    sleep "$HYDRATE_CHECK_INTERVAL"
  done
}

healthbeat() { : > "$HIST_DIR/.backup.alive"; }

# === NEW: commit on ANY change ===
# inotify path: commit per event. For large files: transactional pointerize -> commit; for others: stage+commit.
watch_with_inotify() {
  LOG "使用 inotify 监控本地变化并立即提交备份（小文件也会提交）"
  local paths=()
  for t in $TARGETS; do
    local root="${HIST_DIR%/}/$t"
    [ -e "$root" ] && paths+=("$root")
  done
  [ ${#paths[@]} -eq 0 ] && { LOG "无可监控路径"; return 0; }
  inotifywait -m -r -e close_write,move,create,delete,attrib "${paths[@]}" --format '%e %w%f' 2>/dev/null \
    | while read -r ev f; do
        local rel_rel="${f#${HIST_DIR%/}/}"
        # 无论何种事件，先快速判断是否在黑名单（删除事件 f 可能不存在，但路径仍可判断）
        is_excluded_rel "$rel_rel" && continue

        if [ -f "$f" ] && [ "${f##*.}" != "pointer" ]; then
          local sz; sz="$(file_size "$f" || echo 0)"
          if [ "$sz" -ge "$LARGE_THRESHOLD" ]; then
            LOG "检测到大文件变更：$ev $rel_rel ($sz bytes)"
            pointerize_txn "$f" || true
            # pointerize_txn 内部已 commit_local
          else
            LOG "检测到小文件变更：$ev $rel_rel"
            git -C "$HIST_DIR" add -A -- "$rel_rel" || true
            commit_local || true
          fi
        else
          # 可能是删除/重命名/指针文件/属性变化等：直接全量 stage 再提交，确保删除被记录
          LOG "检测到非普通文件事件：$ev $rel_rel（或文件已删除）"
          git -C "$HIST_DIR" add -A || true
          commit_local || true
        fi
        healthbeat
      done
}

# scan fallback: each interval stage deletions and small-file changes; large files go via pointerize_txn (and commit inside)
scan_delta_since() {
  local since_ts="$1"
  LOG "缺少 inotify，降级为定时扫描（提交任何变化）"
  while true; do
    local now; now="$(now_ts)"
    local any_change=0

    # Handle large files first (transactional pointer + commit inside)
    for t in $TARGETS; do
      local root="${HIST_DIR%/}/$t"
      [ -e "$root" ] || continue
      if [ -d "$root" ]; then
        find "$root" -type f -not -name '*.pointer' -not -path '*/.git/*' -printf '%T@ %p\n' 2>/dev/null \
          | awk -v th="$since_ts" '{ if ($1>th) { $1=""; sub(/^ /,""); print } }' \
          | while read -r f; do
              [ -f "$f" ] || continue
              local rel_rel="${f#${HIST_DIR%/}/}"; is_excluded_rel "$rel_rel" && continue
              local sz; sz="$(file_size "$f" || echo 0)"
              if [ "$sz" -ge "$LARGE_THRESHOLD" ]; then
                LOG "发现最近变更（大文件）：$rel_rel ($sz bytes)"
                pointerize_txn "$f" || true
              else
                LOG "发现最近变更（小文件）：$rel_rel"
                git -C "$HIST_DIR" add -A -- "$rel_rel" || true
                any_change=1
              fi
            done
      elif [ -f "$root" ]; then
        local f="$root"; local m; m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
        if [ "$m" -gt "$since_ts" ]; then
          local rel_rel="${f#${HIST_DIR%/}/}"; is_excluded_rel "$rel_rel" && continue
          local sz; sz="$(file_size "$f" || echo 0)"
          if [ "$sz" -ge "$LARGE_THRESHOLD" ]; then
            LOG "发现最近变更（大文件）：$rel_rel ($sz bytes)"
            pointerize_txn "$f" || true
          else
            LOG "发现最近变更（小文件）：$rel_rel"
            git -C "$HIST_DIR" add -A -- "$rel_rel" || true
            any_change=1
          fi
        fi
      fi
    done

    # Stage deletions and anything missed, then commit once per cycle if needed
    git -C "$HIST_DIR" add -A || true
    if [ $any_change -eq 1 ]; then
      commit_local || true
    else
      # even if any_change=0, there might be deletions; commit_local will skip if nothing staged
      commit_local || true
    fi

    healthbeat
    since_ts="$now"
    [ $STOP_REQUESTED -eq 1 ] && break
    sleep "$SCAN_INTERVAL_SECS"
  done
}

precreate_dirlike_targets() {
  for target in $DIRLIKE_TARGETS; do
    local dst="${HIST_DIR%/}/$target"
    local rel_rel="$target"
    is_excluded_rel "$rel_rel" && continue
    mkdir -p "$dst" 2>/dev/null || true
  done
}
track_empty_dirs() {
  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    [ -d "$root" ] || continue
    find "$root" -type d -empty -not -path '*/.git/*' -print0 2>/dev/null \
      | while IFS= read -r -d '' d; do
          local rel_rel="${d#${HIST_DIR%/}/}"
          is_excluded_rel "$rel_rel" && continue
          : > "$d/.gitkeep"
          git -C "$HIST_DIR" add -f -- "$rel_rel/.gitkeep" >/dev/null 2>&1 || true
        done
  done
}

do_init() {
  ensure_repo
  apply_exclude_rules || true
  precreate_dirlike_targets || true
  link_targets
  pointerize_txn || true
  ensure_pointer_merge_config || true
  commit_local || true
  hydrate_from_pointers || true
  chmod -R 777 "$HIST_DIR" || true
  LOG "初始化完成（拉取一次 + 指针化一次 + 回填一次）"
}

start_monitor() {
  LOG "监控模式：不会再拉取远端；检测到任何本地变化就上传/提交（可选 push）"
  if need_cmd inotifywait; then
    watch_with_inotify
  else
    scan_delta_since "$(now_ts)"
  fi
}

case "$MODE" in
  init)    do_init ;;
  daemon)  do_init ; start_monitor ;;
  monitor) start_monitor ;;
  restore) ensure_repo; apply_exclude_rules; hydrate_from_pointers ;;
  wait)
    LOG "等待备份初始化完成..."
    ensure_repo
    apply_exclude_rules || true
    precreate_dirlike_targets || true
    link_targets
    pointerize_txn || true
    hydrate_from_pointers || true
    wait_until_hydrated || true ;;
  *) ERR "未知模式：$MODE（应为 init|daemon|monitor|restore|wait）"; exit 2 ;;
esac
SCAN_INTERVAL_SECS=${SCAN_INTERVAL_SECS:-$BACKUP_INTERVAL_SECONDS}

# 策略开关
PULL_POLICY=${PULL_POLICY:-once}            # once|never （init/restore 时有效；monitor/daemon 不再 pull）
AUTO_PUSH=${AUTO_PUSH:-false}               # 是否自动 push 到远端；默认 false
ALWAYS_KEEP_LOCAL=${ALWAYS_KEEP_LOCAL:-true}
MAX_ASSET_VERSIONS=${MAX_ASSET_VERSIONS:-3} # 每个 base 文件名保留的 Release 资产版本数

# Git 基本参数
GIT_BRANCH=${GIT_BRANCH:-main}
GIT_USER_NAME=${GIT_USER_NAME:-astrbot-backup}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-astrbot-backup@local}
GIT_OP_TIMEOUT=${GIT_OP_TIMEOUT:-25}
# 首次同步等待：0 表示无限等待。
INIT_SYNC_TIMEOUT=${INIT_SYNC_TIMEOUT:-0}
INIT_SYNC_CHECK_INTERVAL=${INIT_SYNC_CHECK_INTERVAL:-3}

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
KEEP_OLD_ASSETS=${KEEP_OLD_ASSETS:-false}    # 保留旧资产的兼容变量；此版本将由 MAX_ASSET_VERSIONS 控制
STICKY_POINTER=${STICKY_POINTER:-true}       # 兼容变量；若 ALWAYS_KEEP_LOCAL=true 将被忽略
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

# 目录型目标（相对 BASE）：用于在仓库中预创建目录并跟踪空目录
DIRLIKE_TARGETS=${DIRLIKE_TARGETS:-"home/user/AstrBot/data home/user/config app/napcat/config app/.config/QQ home/user/gemini-data"}

# 默认排除目录（相对 HIST_DIR 的路径）
EXCLUDE_PATHS=${EXCLUDE_PATHS:-"home/user/AstrBot/data/plugin_data/jm_cosmos home/user/AstrBot/data/memes_data /home/user/AstrBot/data/temp"}

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

# ====== 黑名单辅助 ======
is_excluded_rel() {
  local rel="$1"; rel="${rel#./}"
  for ex in $EXCLUDE_PATHS; do
    ex="${ex#./}"
    case "$rel" in
      "$ex"|"$ex"/*) return 0 ;;
    esac
  done
  return 1
}

ensure_git_exclude_entry() {
  local rel="$1"; local exfile="$HIST_DIR/.git/info/exclude"
  mkdir -p "$(dirname "$exfile")" 2>/dev/null || true
  touch "$exfile"
  grep -Fxq -- "$rel" "$exfile" 2>/dev/null || echo "$rel" >> "$exfile"
}

apply_exclude_rules() {
  for ex in $EXCLUDE_PATHS; do
    ensure_git_exclude_entry "$ex"
  done
}

# ====== Git ======
git_cfg() {
  git -C "$HIST_DIR" config user.name "$GIT_USER_NAME" || true
  git -C "$HIST_DIR" config user.email "$GIT_USER_EMAIL" || true
  git -C "$HIST_DIR" config pull.rebase true || true
  git config --global --add safe.directory "$HIST_DIR" >/dev/null 2>&1 || true
}

remote_url() {
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
    if [ "$PULL_POLICY" = "once" ]; then
      # 仅首次拉取一次
      local start_ts; start_ts="$(now_ts)"
      local target_branch="$GIT_BRANCH"
      while true; do
        if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" ls-remote --exit-code origin >/dev/null 2>&1; then
          if ! run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" ls-remote --exit-code --heads origin "$GIT_BRANCH" >/dev/null 2>&1; then
            local head_line head_ref
            head_line="$(run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" ls-remote --symref origin HEAD 2>/dev/null || true)"
            head_ref="$(printf '%s' "$head_line" | awk '/^ref:/{print $2}' | sed 's#refs/heads/##' 2>/dev/null || true)"
            [ -n "$head_ref" ] && target_branch="$head_ref" || target_branch="$GIT_BRANCH"
            LOG "远端未找到分支 '$GIT_BRANCH'，使用默认分支 '$target_branch' 进行首次同步"
          fi
          if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" fetch --depth=1 origin "$target_branch"; then
            git -C "$HIST_DIR" checkout -B "$target_branch" || true
            if run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" reset --hard "origin/$target_branch"; then
              LOG "首次拉取完成：origin/$target_branch"; GIT_BRANCH="$target_branch"; break
            fi
          fi
          LOG "拉取未完成，稍后重试（branch=$target_branch）..."
        else
          LOG "无法访问远端仓库，等待网络/凭据可用后重试..."
        fi
        if [ "$INIT_SYNC_TIMEOUT" != "0" ]; then
          local elapsed=$(( $(now_ts) - start_ts ))
          if [ "$elapsed" -ge "$INIT_SYNC_TIMEOUT" ]; then
            ERR "首次拉取等待超时(${INIT_SYNC_TIMEOUT}s)，将继续初始化（可能缺少远端最新内容）"
            break
          fi
        fi
        sleep "$INIT_SYNC_CHECK_INTERVAL"
      done
    else
      LOG "PULL_POLICY=never：跳过首次拉取"
      git -C "$HIST_DIR" checkout -B "$GIT_BRANCH" || true
    fi
  else
    LOG "未配置远端（GITHUB_* 或 github_*），将仅使用本地历史仓库"
    git -C "$HIST_DIR" checkout -B "$GIT_BRANCH" || true
  fi
}

commit_local() {
  git -C "$HIST_DIR" add -A
  if git -C "$HIST_DIR" diff --cached --quiet; then
    LOG "工作区无变更，跳过提交"
    return 0
  fi
  git -C "$HIST_DIR" commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')"
  LOG "已提交变更（本地）"
  if [ "$AUTO_PUSH" = "true" ] && git -C "$HIST_DIR" remote | grep -q '^origin$'; then
    # 按需推送；不再执行 pull（避免回到“拉取-推送循环”）
    if ! run_to "$GIT_OP_TIMEOUT" git -C "$HIST_DIR" push -u origin "$GIT_BRANCH"; then
      ERR "push 失败/被拒绝，已保留本地提交"
    else
      LOG "push 成功"
    fi
  fi
}

# ====== 目标迁移与链接 ======
ensure_gitignore_entry() { local rel="$1"; local gi="$HIST_DIR/.gitignore"; touch "$gi"; grep -Fxq -- "$rel" "$gi" || echo "$rel" >> "$gi"; }

ensure_gitattributes_entry() {
  local pattern="$1"; shift
  local attrs="$*"
  local gaf="$HIST_DIR/.gitattributes"
  mkdir -p "$(dirname "$gaf")" 2>/dev/null || true
  touch "$gaf"
  if ! grep -Fqx -- "$pattern $attrs" "$gaf" 2>/dev/null; then
    echo "$pattern $attrs" >> "$gaf"
  fi
  git -C "$HIST_DIR" add -f -- .gitattributes >/dev/null 2>&1 || true
}

ensure_pointer_merge_config() {
  git -C "$HIST_DIR" config merge.ours.driver true >/dev/null 2>&1 || true
  ensure_gitattributes_entry "*.pointer" "merge=ours"
}

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

# ====== GitHub Release 资产与指针 ======
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

gh_list_assets_json() {
  local rid="$1"; [ -n "$rid" ] || return 1
  local api="https://api.github.com"; gh_api GET "$api/repos/$github_project/releases/$rid/assets"
}

gh_find_asset_id() {
  local rid="$1" name="$2"
  [ -n "$rid" ] || return 1
  gh_list_assets_json "$rid" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1
}

gh_delete_asset() {
  local asset_id="$1"; [ -n "$asset_id" ] || return 1
  local api="https://api.github.com/repos/${github_project}/releases/assets/${asset_id}"
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "$api")"
  if [ "$code" = "204" ]; then LOG "删除历史资产：id=$asset_id"; else ERR "删除历史资产失败：id=$asset_id code=$code"; fi
}

pointer_path_for() { local f="$1"; echo "$f.pointer"; }

# 只在确认上传成功后，再写指针；永远不删除本地大文件
write_pointer_after_confirm() {
  local rid="$1" f="$2" rel_rel="$3" size="$4" sha="$5"
  local base name aid url ptr
  base="$(basename "$f")"; name="${sha}-${base}"; ptr="$(pointer_path_for "$f")"
  aid="$(gh_find_asset_id "$rid" "$name" || true)"
  if [ -z "$aid" ]; then
    LOG "上传大文件到 Release: $rel_rel ($size bytes)"
    if ! gh_upload_asset "$rid" "$f" "$name" >/dev/null 2>&1; then
      ERR "上传失败：$rel_rel"; return 1
    fi
    aid="$(gh_find_asset_id "$rid" "$name" || true)"
    if [ -z "$aid" ]; then ERR "上传确认失败：$rel_rel"; return 1; fi
  fi
  url="https://github.com/${github_project}/releases/download/${RELEASE_TAG}/$(urlencode "$name")"
  # 资源可达性校验（HEAD）
  if ! curl -sS -I ${github_secret:+-H "Authorization: Bearer ${github_secret}"} "$url" | head -n1 | grep -qE ' 200 | 302 '; then
    ERR "上传后资源不可用：$rel_rel ($url)"; return 1
  fi
  # 写指针（确认成功之后）
  jq -nc \
    --arg repo "$github_project" \
    --arg tag "$RELEASE_TAG" \
    --arg asset "$name" \
    --arg asset_id "${aid:-}" \
    --arg url "$url" \
    --arg path "$rel_rel" \
    --arg size "$size" \
    --arg sha "$sha" '{
      type:"release-asset", repo:$repo, release_tag:$tag,
      asset_name:$asset, asset_id:( ($asset_id|tonumber?) // null ),
      download_url:$url, original_path:$path,
      size:(($size|tonumber?) // 0), sha256:$sha, generated_at:(now|todate)
    }' > "$ptr"
  git -C "$HIST_DIR" add -f "$ptr" || true

  # 永远保留本地原文件：忽略 STICKY_POINTER
  if [ "$ALWAYS_KEEP_LOCAL" = "true" ]; then :; else :; fi

  # 版本保留策略：每个 base 文件名仅保留最近 MAX_ASSET_VERSIONS 个资产
  enforce_asset_retention "$rid" "$base" "$MAX_ASSET_VERSIONS" "$name"
}

enforce_asset_retention() {
  local rid="$1" base="$2" keep="$3" current_name="$4"
  [ -n "$rid" ] || return 0
  local list; list="$(gh_list_assets_json "$rid" || echo '[]')"
  # 仅匹配形如 "<sha256>-<base>" 的资产名，并按 id 排序（id 越大越新）
  # 删除多余的旧版本，但不删除当前正在引用的资产
  echo "$list" | jq -r --arg base "$base" --arg cur "$current_name" --argjson keep "$keep" '
    [ .[]
      | select(.name | test("^[0-9a-fA-F]{64}-" + ($base|gsub("\\W"; "\\\\$0")) + "$"))
      | {id: .id, name: .name}
    ] | sort_by(.id) as $all
      | if ($all|length) > $keep
        then ($all|.[0:(length - $keep)] | map(select(.name != $cur)) | .[].id)
        else empty
        end
  ' | while read -r old_id; do
    [ -n "$old_id" ] && gh_delete_asset "$old_id"
  done
}

gh_upload_asset() {
  local rid="$1" file="$2" name="$3"
  [ -n "$rid" ] || return 1
  curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Content-Type: application/octet-stream" --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${rid}/assets?name=$(urlencode "$name")"
}

# 事务式指针化（可按需要传入仅处理的路径）；默认遍历 TARGETS
pointerize_txn() {
  [ -n "$github_project" ] && [ -n "$github_secret" ] || { LOG "未配置 github_project/github_secret，跳过大文件指针化"; return 0; }
  local rid; rid="$(gh_ensure_release || true)" || rid=""
  [ -n "$rid" ] || { ERR "无法确保 Release：$RELEASE_TAG"; return 1; }

  local only_path="${1:-}"
  if [ -n "$only_path" ]; then
    local f="$only_path"
    if [ -f "$f" ]; then
      local sz sha rel_rel
      sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || return 0
      sha="$(sha256_of "$f")"; rel_rel="${f#${HIST_DIR%/}/}"
      is_excluded_rel "$rel_rel" && return 0
      ensure_gitignore_entry "$rel_rel"
      write_pointer_after_confirm "$rid" "$f" "$rel_rel" "$sz" "$sha" || return 1
      commit_local || true
    fi
    return 0
  fi

  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    [ -e "$root" ] || continue
    if [ -d "$root" ]; then
      find "$root" -type f -not -name '*.pointer' -not -path '*/.git/*' -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            local sz sha rel_rel
            sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
            sha="$(sha256_of "$f")"; rel_rel="${f#${HIST_DIR%/}/}"
            is_excluded_rel "$rel_rel" && continue
            ensure_gitignore_entry "$rel_rel"
            write_pointer_after_confirm "$rid" "$f" "$rel_rel" "$sz" "$sha" || true
          done
    elif [ -f "$root" ]; then
      local f="$root" sz sha rel_rel
      sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
      sha="$(sha256_of "$f")"; rel_rel="${f#${HIST_DIR%/}/}"
      is_excluded_rel "$rel_rel" && continue
      ensure_gitignore_entry "$rel_rel"
      write_pointer_after_confirm "$rid" "$f" "$rel_rel" "$sz" "$sha" || true
    fi
  done
  commit_local || true
}

try_curl_download() {
  local url="$1"; shift
  local outfile="$1"; shift
  local allow_retry="$1"; shift
  local headers=("$@")
  local attempt=1
  while :; do
    if curl -fsSL -o "$outfile" "${headers[@]}" "$url"; then return 0; fi
    [ "$allow_retry" = "false" ] && return 1
    [ $attempt -ge $DOWNLOAD_RETRY ] && return 1
    sleep 1; attempt=$((attempt+1))
  done
}

# 从当前指针失败时，回退到“上一版本”下载（按 Release asset id 排序）
download_previous_version() {
  local repo="$1" tag="$2" base="$3" cur_name="$4" out="$5"
  local res; res="$(gh_api GET "https://api.github.com/repos/${repo}/releases/tags/${tag}")" || true
  # 取所有匹配 base 的资产，按 id 排序，找到 cur_name 的前一个
  local prev_url prev_id
  prev_url="$(echo "$res" | jq -r --arg base "$base" --arg cur "$cur_name" '
    .assets // []
    | map(select(.name | test("^[0-9a-fA-F]{64}-" + ($base|gsub("\\W"; "\\\\$0")) + "$"))) 
    | sort_by(.id) as $arr
    | ($arr | map(.name) | index($cur)) as $idx
    | if ($idx != null and $idx > 0) then ($arr[$idx-1].browser_download_url // empty) else "" end
  ' 2>/dev/null || echo "")"
  prev_id="$(echo "$res" | jq -r --arg base "$base" --arg cur "$cur_name" '
    .assets // []
    | map(select(.name | test("^[0-9a-fA-F]{64}-" + ($base|gsub("\\W"; "\\\\$0")) + "$")))
    | sort_by(.id) as $arr
    | ($arr | map(.name) | index($cur)) as $idx
    | if ($idx != null and $idx > 0) then ($arr[$idx-1].id // empty) else "" end
  ' 2>/dev/null || echo "")"
  [ -z "$prev_url$prev_id" ] && return 1

  local headers2=()
  [ -n "$github_secret" ] && headers2=(-H "Authorization: Bearer ${github_secret}")
  if [ -n "$prev_id" ]; then
    local api="https://api.github.com/repos/${repo}/releases/assets/${prev_id}"
    headers2=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
    try_curl_download "$api" "$out" true "${headers2[@]}"
  else
    try_curl_download "$prev_url" "$out" true "${headers2[@]}"
  fi
}

hydrate_one_pointer() {
  local ptr="$1"
  local rel path repo tag name url size sha aid dst tmp base
  rel="$(jq -r '.original_path // empty' "$ptr" 2>/dev/null || echo "")"; [ -n "$rel" ] || return 1
  path="${HIST_DIR%/}/$rel"; repo="$(jq -r '.repo // empty' "$ptr" 2>/dev/null || echo "")"
  tag="$(jq -r '.release_tag // "blobs"' "$ptr" 2>/dev/null)"
  name="$(jq -r '.asset_name // empty' "$ptr" 2>/dev/null || echo "")"
  url="$(jq -r '.download_url // empty' "$ptr" 2>/dev/null || echo "")"
  size="$(jq -r '.size // 0' "$ptr" 2>/dev/null || echo 0)"
  sha="$(jq -r '.sha256 // empty' "$ptr" 2>/dev/null || echo "")"
  aid="$(jq -r '.asset_id // empty' "$ptr" 2>/dev/null || echo "")"
  base="$(basename "$name" | sed 's/^[0-9a-fA-F]\{64\}-//')" || base=""
  [ -n "$repo" ] || repo="$github_project"
  [ -n "$repo" ] || { ERR "指针缺少 repo：$ptr"; return 1; }
  mkdir -p "$(dirname "$path")"
  dst="$path"; tmp="$(mktemp)"

  local headers=()
  [ -n "$github_secret" ] && headers=(-H "Authorization: Bearer ${github_secret}")
  # 黑名单直接跳过
  if is_excluded_rel "$rel"; then
    LOG "跳过黑名单指针：$rel"
    return 0
  fi

  local ok=0
  if [ -n "$aid" ]; then
    local api="https://api.github.com/repos/${repo}/releases/assets/${aid}"
    if try_curl_download "$api" "$tmp" true "${headers[@]}" -H "Accept: application/octet-stream"; then ok=1; fi
  elif [ -n "$url" ]; then
    if try_curl_download "$url" "$tmp" true "${headers[@]}"; then ok=1; fi
  fi

  if [ "$ok" != "1" ]; then
    LOG "当前版本下载失败，尝试回退到上一版本：$rel"
    if ! download_previous_version "$repo" "$tag" "$base" "$name" "$tmp"; then
      ERR "回退下载失败：$rel"
      rm -f "$tmp"; return 1
    fi
    # 回退版本：无法与当前指针的 size/sha 对齐，跳过严格校验，仅记录尺寸
    local got_sz; got_sz="$(file_size "$tmp" || echo 0)"
    LOG "已回退下载上一版本（$got_sz bytes）：$rel"
  else
    # 正常路径：严格校验
    local got_sz; got_sz="$(file_size "$tmp" || echo 0)"
    if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_sz" != "$size" ]; then ERR "大小不匹配：$rel"; rm -f "$tmp"; return 1; fi
    if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then
      local got_sha; got_sha="$(sha256_of "$tmp")"; [ "$got_sha" = "$sha" ] || { ERR "SHA 不匹配：$rel"; rm -f "$tmp"; return 1; }
    fi
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
        if is_excluded_rel "$rel"; then total=$((total-1)); continue; fi
        size="$(jq -r '.size // 0' "$p" 2>/dev/null || echo 0)"; sha="$(jq -r '.sha256 // empty' "$p" 2>/dev/null || echo "")"
        if [ -f "$dst" ]; then
          local cs; cs="$(file_size "$dst" || echo 0)"
          if [ "$cs" = "$size" ]; then
            if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then local csha; csha="$(sha256_of "$dst")"; [ "$csha" = "$sha" ] && ok=$((ok+1)); else ok=$((ok+1)); fi
          else
            # 回退版本尺寸不同，无法通过 size 档位校验；视为未就绪
            :
          fi
        fi
      done < <(find "$root" -type f -name '*.pointer' -print0 2>/dev/null)
    elif [ -f "${root}.pointer" ]; then
      total=$((total+1))
      local p="${root}.pointer" rel dst size sha
      rel="$(jq -r '.original_path // empty' "$p" 2>/dev/null || echo "")"; dst="${HIST_DIR%/}/$rel"; size="$(jq -r '.size // 0' "$p" 2>/dev/null || echo 0)"; sha="$(jq -r '.sha256 // empty' "$p" 2>/dev/null || echo "")"
      if is_excluded_rel "$rel"; then total=$((total-1)); else
        if [ -f "$dst" ]; then
          local cs; cs="$(file_size "$dst" || echo 0)"
          if [ "$cs" = "$size" ]; then if [ "$VERIFY_SHA" = "true" ] && [ -n "$sha" ]; then local csha; csha="$(sha256_of "$dst")"; [ "$csha" = "$sha" ] && ok=$((ok+1)); else ok=$((ok+1)); fi; fi
        fi
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
    if all_pointers_hydrated >/dev/null 2>&1; then LOG "数据就绪：$prog"; break; else LOG "进度：$prog（含可能回退版本），继续等待..."; fi
    if [ "$HYDRATE_TIMEOUT" != "0" ]; then local elapsed=$(( $(now_ts) - start_ts )); [ "$elapsed" -ge "$HYDRATE_TIMEOUT" ] && { ERR "等待超时（$HYDRATE_TIMEOUT s）"; return 1; }; fi
    sleep "$HYDRATE_CHECK_INTERVAL"
  done
}

# ====== 监控：只上传更新，不再拉取 ======
healthbeat() { : > "$HIST_DIR/.backup.alive"; }

watch_with_inotify() {
  LOG "使用 inotify 监控本地变化并上传更新（仅处理 ≥ $LARGE_THRESHOLD 字节的文件）"
  local paths=()
  for t in $TARGETS; do
    local root="${HIST_DIR%/}/$t"
    [ -e "$root" ] && paths+=("$root")
  done
  [ ${#paths[@]} -eq 0 ] && { LOG "无可监控路径"; return 0; }
  inotifywait -m -r -e close_write,move,create "${paths[@]}" --format '%w%f' 2>/dev/null \
    | while read -r f; do
        [ -f "$f" ] || continue
        local rel_rel="${f#${HIST_DIR%/}/}"
        is_excluded_rel "$rel_rel" && continue
        local sz; sz="$(file_size "$f" || echo 0)"
        [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
        LOG "检测到变更：$rel_rel ($sz bytes)"
        pointerize_txn "$f" || true
        healthbeat
      done
}

scan_delta_since() {
  local since_ts="$1"
  LOG "缺少 inotify，降级为定时扫描：自 $since_ts 之后的变更"
  while true; do
    local now; now="$(now_ts)"
    for t in $TARGETS; do
      local root="${HIST_DIR%/}/$t"
      [ -e "$root" ] || continue
      if [ -d "$root" ]; then
        # 查找大于阈值且最近修改的文件
        find "$root" -type f -not -name '*.pointer' -not -path '*/.git/*' -printf '%T@ %p\n' 2>/dev/null \
          | awk -v th="$since_ts" '{ if ($1>th) { $1=""; sub(/^ /,""); print } }' \
          | while read -r f; do
              [ -f "$f" ] || continue
              local rel_rel="${f#${HIST_DIR%/}/}"; is_excluded_rel "$rel_rel" && continue
              local sz; sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
              LOG "发现最近变更：$rel_rel ($sz bytes)"
              pointerize_txn "$f" || true
            done
      elif [ -f "$root" ]; then
        local f="$root"; local m; m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
        if [ "$m" -gt "$since_ts" ]; then
          local rel_rel="${f#${HIST_DIR%/}/}"; is_excluded_rel "$rel_rel" && continue
          local sz; sz="$(file_size "$f" || echo 0)"; [ "$sz" -ge "$LARGE_THRESHOLD" ] || continue
          LOG "发现最近变更：$rel_rel ($sz bytes)"
          pointerize_txn "$f" || true
        fi
      fi
    done
    healthbeat
    since_ts="$now"
    [ $STOP_REQUESTED -eq 1 ] && break
    sleep "$SCAN_INTERVAL_SECS"
  done
}

# ====== 主流程 ======
DIRLIKE_TARGETS=${DIRLIKE_TARGETS:-"home/user/AstrBot/data home/user/config app/napcat/config app/.config/QQ home/user/gemini-data"}

precreate_dirlike_targets() {
  for target in $DIRLIKE_TARGETS; do
    local dst="${HIST_DIR%/}/$target"
    local rel_rel="$target"
    is_excluded_rel "$rel_rel" && continue
    mkdir -p "$dst" 2>/dev/null || true
  done
}

track_empty_dirs() {
  for target in $TARGETS; do
    local root="${HIST_DIR%/}/$target"
    [ -d "$root" ] || continue
    find "$root" -type d -empty -not -path '*/.git/*' -print0 2>/dev/null \
      | while IFS= read -r -d '' d; do
          local rel_rel="${d#${HIST_DIR%/}/}"
          is_excluded_rel "$rel_rel" && continue
          : > "$d/.gitkeep"
          git -C "$HIST_DIR" add -f -- "$rel_rel/.gitkeep" >/dev/null 2>&1 || true
        done
  done
}

do_init() {
  ensure_repo
  apply_exclude_rules || true
  precreate_dirlike_targets || true
  link_targets
  # 首次：指针化 + 回填（一次性）
  pointerize_txn || true
  ensure_pointer_merge_config || true
  commit_local || true
  hydrate_from_pointers || true
  chmod -R 777 "$HIST_DIR" || true
  LOG "初始化完成（拉取一次 + 指针化一次 + 回填一次）"
}

start_monitor() {
  LOG "进入监控模式：只拉取一次，后续仅监控本地变化并上传；不再执行定期 pull/push/hydrate 循环"
  if need_cmd inotifywait; then
    watch_with_inotify
  else
    scan_delta_since "$(now_ts)"
  fi
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
    # 单次回填（带回退）
    ensure_repo; apply_exclude_rules; hydrate_from_pointers ;;
  wait)
    LOG "等待备份初始化完成（仓库/指针/大文件）..."
    ensure_repo
    apply_exclude_rules || true
    precreate_dirlike_targets || true
    link_targets
    pointerize_txn || true
    hydrate_from_pointers || true
    wait_until_hydrated || true ;;
  *)
    ERR "未知模式：$MODE（应为 init|daemon|monitor|restore|wait）"; exit 2 ;;
esac
