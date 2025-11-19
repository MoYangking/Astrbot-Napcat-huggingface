from __future__ import annotations

"""最小管理 API/页面（可选）

职责：
- 提供状态查询 `/sync/api/status`（包含本地与远端 HEAD）；
- 一次性操作：`/sync/api/init`、`/sync/api/sync-now`、`/sync/api/pull`、`/sync/api/push`、`/sync/api/relink`、`/sync/api/track-empty`；
- 目标/黑名单管理：`/sync/api/targets`, `/sync/api/excludes`（持久化到 HIST_DIR/sync-config.json）。

注意：
- 所有路由均以 `/sync` 为前缀，静态页面也挂载到 `/sync`；
- 本模块不强制依赖守护进程，若传入 daemon 句柄，`sync-now` 可直接调用守护的同步方法。 
"""

import os
from typing import Dict

from sync.core import git_ops
from sync.core.blacklist import ensure_git_info_exclude
from sync.core.config import load_settings, save_file_overrides
from sync.core.linker import migrate_and_link, precreate_dirlike, track_empty_dirs
from sync.utils.logging import log, err


def _remote_url(pat: str, repo: str) -> str:
    """构造 x-access-token 形式的 GitHub 远端 URL。"""
    return f"https://x-access-token:{pat}@github.com/{repo}.git"


def create_app(daemon=None):
    """创建 FastAPI 应用实例。

    参数：
    - daemon: 可选的 SyncDaemon 实例；若提供，`/sync/api/sync-now` 将直接调用其同步方法。
    """
    # Lazy import to avoid hard dependency when not serving
    from fastapi import FastAPI
    from fastapi.staticfiles import StaticFiles
    from fastapi.responses import JSONResponse

    app = FastAPI(title="Sync Manager", version="0.2.0")

    @app.get("/sync/api/status")
    def api_status() -> Dict:
        """返回运行时状态（JSON）。

        字段：
        - branch/repo/hist_dir/base：基础配置摘要；
        - targets/excludes：当前目标与黑名单；
        - git_initialized：是否存在 .git；dirty：是否有未提交变更；
        - head/remote_head：本地 HEAD 与远端 HEAD（便于前端判断是否已对齐）。
        """
        st = load_settings()
        ready = os.path.exists(st.ready_file)
        have_git = os.path.isdir(os.path.join(st.hist_dir, ".git"))
        try:
            proc = git_ops.run(["git", "status", "--porcelain"], cwd=st.hist_dir, check=False)
            dirty = bool(proc.stdout.strip())
        except Exception:
            dirty = False
        # 提供 HEAD 与远端 HEAD 用于前端展示同步进度
        try:
            head = git_ops.run(["git", "rev-parse", "HEAD"], cwd=st.hist_dir, check=False).stdout.strip()
        except Exception:
            head = ""
        try:
            rhead = git_ops.run(["git", "rev-parse", f"origin/{st.branch}"], cwd=st.hist_dir, check=False).stdout.strip()
        except Exception:
            rhead = ""
        return {
            "base": st.base,
            "hist_dir": st.hist_dir,
            "branch": st.branch,
            "repo": st.github_repo,
            "targets": st.targets,
            "excludes": st.excludes,
            "ready": ready,
            "git_initialized": have_git,
            "dirty": dirty,
            "head": head,
            "remote_head": rhead,
        }

    @app.post("/sync/api/init")
    def api_init():
        """一次性：确保仓库 -> 拉取或初始化 -> 迁移链接 -> 空目录跟踪 -> 提交推送。"""
        st = load_settings()
        try:
            git_ops.ensure_repo(st.hist_dir, st.branch)
            ensure_git_info_exclude(st.hist_dir, st.excludes)
            git_ops.set_remote(st.hist_dir, _remote_url(st.github_pat, st.github_repo))
            if git_ops.remote_is_empty(st.hist_dir):
                git_ops.initial_commit_if_needed(st.hist_dir)
                git_ops.push(st.hist_dir, st.branch)
            else:
                git_ops.fetch_and_checkout(st.hist_dir, st.branch)
            precreate_dirlike(st.hist_dir, st.targets)
            migrate_and_link(st.base, st.hist_dir, st.targets)
            track_empty_dirs(st.hist_dir, st.targets, st.excludes)
            changed = git_ops.add_all_and_commit_if_needed(st.hist_dir, "chore(sync): link and track empty dirs")
            if changed:
                git_ops.push(st.hist_dir, st.branch)
            return {"ok": True}
        except Exception as e:
            err(str(e))
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 立即同步（pull→commit→push）
    @app.post("/sync/api/sync-now")
    def api_sync_now():
        """立即执行一次同步：pull --rebase → commit（如有）→ push。"""
        try:
            if daemon is not None:
                daemon.pull_commit_push()
                return {"ok": True}
            # 后备：直接按流程执行
            st = load_settings()
            git_ops.run(["git", "pull", "--rebase", "origin", st.branch], cwd=st.hist_dir, check=False)
            changed = git_ops.add_all_and_commit_if_needed(st.hist_dir, "chore(sync): sync-now")
            if changed:
                git_ops.push(st.hist_dir, st.branch)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 仅拉取
    @app.post("/sync/api/pull")
    def api_pull():
        """仅执行一次 `git pull --rebase`。"""
        try:
            st = load_settings()
            git_ops.run(["git", "pull", "--rebase", "origin", st.branch], cwd=st.hist_dir, check=False)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 仅推送
    @app.post("/sync/api/push")
    def api_push():
        """仅执行一次 `git push`。"""
        try:
            st = load_settings()
            git_ops.run(["git", "push", "origin", st.branch], cwd=st.hist_dir, check=False)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 重新链接并跟踪空目录
    @app.post("/sync/api/relink")
    def api_relink():
        """重新进行迁移与软链，并跟踪空目录；随后提交推送（如有变更）。"""
        try:
            st = load_settings()
            precreate_dirlike(st.hist_dir, st.targets)
            migrate_and_link(st.base, st.hist_dir, st.targets)
            track_empty_dirs(st.hist_dir, st.targets, st.excludes)
            changed = git_ops.add_all_and_commit_if_needed(st.hist_dir, "chore(sync): relink & empty")
            if changed:
                git_ops.push(st.hist_dir, st.branch)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 仅扫描空目录
    @app.post("/sync/api/track-empty")
    def api_track_empty():
        """扫描空目录写入 .gitkeep，并提交推送（如有变更）。"""
        try:
            st = load_settings()
            cnt = track_empty_dirs(st.hist_dir, st.targets, st.excludes)
            changed = git_ops.add_all_and_commit_if_needed(st.hist_dir, f"chore(sync): track empty ({cnt})")
            if changed:
                git_ops.push(st.hist_dir, st.branch)
            return {"ok": True, "written": cnt}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 目标与黑名单管理
    @app.get("/sync/api/targets")
    def api_get_targets():
        """返回当前同步目标（数组）。"""
        st = load_settings()
        return {"targets": st.targets}

    @app.post("/sync/api/targets")
    def api_set_targets(payload: dict):
        """覆盖保存同步目标（数组）到配置文件。"""
        try:
            st = load_settings()
            data = {"targets": payload.get("targets", st.targets), "excludes": st.excludes}
            save_file_overrides(st.hist_dir, data)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    @app.get("/sync/api/excludes")
    def api_get_excludes():
        """返回当前黑名单（数组）。"""
        st = load_settings()
        return {"excludes": st.excludes}

    @app.post("/sync/api/excludes")
    def api_set_excludes(payload: dict):
        """覆盖保存黑名单（数组）到配置文件，并更新 git info/exclude。"""
        try:
            st = load_settings()
            data = {"targets": st.targets, "excludes": payload.get("excludes", st.excludes)}
            save_file_overrides(st.hist_dir, data)
            ensure_git_info_exclude(st.hist_dir, data["excludes"])
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 新增 API：Git 日志
    @app.get("/sync/api/logs")
    def api_logs(n: int = 20):
        """获取最近 n 条提交日志。"""
        st = load_settings()
        try:
            # %h: short hash, %s: subject, %cr: committer date, relative, %an: author name
            cmd = ["git", "log", f"-n{n}", "--pretty=format:%h|%s|%cr|%an"]
            res = git_ops.run(cmd, cwd=st.hist_dir, check=False)
            if res.returncode != 0:
                return {"ok": False, "error": res.stderr}
            
            logs = []
            for line in res.stdout.strip().splitlines():
                parts = line.split("|")
                if len(parts) >= 4:
                    logs.append({
                        "hash": parts[0],
                        "message": parts[1],
                        "date": parts[2],
                        "author": parts[3]
                    })
            return {"ok": True, "logs": logs}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 新增 API：强制重置
    @app.post("/sync/api/reset")
    def api_reset():
        """强制重置本地更改：git reset --hard HEAD && git clean -fd"""
        st = load_settings()
        try:
            git_ops.run(["git", "reset", "--hard", "HEAD"], cwd=st.hist_dir)
            git_ops.run(["git", "clean", "-fd"], cwd=st.hist_dir)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 新增 API：列出文件
    @app.get("/sync/api/files")
    def api_files(limit: int = 100):
        """列出当前仓库文件（git ls-files）。"""
        st = load_settings()
        try:
            res = git_ops.run(["git", "ls-files"], cwd=st.hist_dir, check=False)
            if res.returncode != 0:
                return {"ok": False, "error": res.stderr}
            
            all_files = res.stdout.strip().splitlines()
            count = len(all_files)
            files = all_files[:limit]
            return {"ok": True, "files": files, "total": count, "limit": limit}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # LFS 大文件管理 API
    @app.get("/sync/api/lfs/status")
    def api_lfs_status():
        """返回 LFS 状态和配置信息"""
        st = load_settings()
        return {
            "enabled": st.lfs_enabled,
            "threshold": st.lfs_threshold,
            "release_tag": st.lfs_release_tag,
            "max_versions": st.lfs_max_versions,
            "max_workers": st.lfs_max_workers
        }
    
    @app.post("/sync/api/lfs/scan")
    def api_lfs_scan():
        """扫描大文件（不上传）"""
        try:
            if daemon is None:
                return JSONResponse({"ok": False, "error": "Daemon not available"}, status_code=503)
            
            if not daemon._lfs_api or not daemon._lfs_manifest:
                return JSONResponse({"ok": False, "error": "LFS not enabled"}, status_code=400)
            
            from sync.core.lfs_ops import scan_large_files
            st = load_settings()
            
            large_files = scan_large_files(
                st.hist_dir,
                st.lfs_threshold,
                st.excludes
            )
            
            # 转换为相对路径
            files = [os.path.relpath(f, st.hist_dir) for f in large_files]
            
            return {
                "ok": True,
                "files": files,
                "count": len(files),
                "threshold_mb": st.lfs_threshold / (1024 * 1024)
            }
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    
    @app.post("/sync/api/lfs/upload")
    def api_lfs_upload():
        """手动触发大文件上传"""
        try:
            if daemon is None:
                return JSONResponse({"ok": False, "error": "Daemon not available"}, status_code=503)
            
            if not daemon._lfs_api or not daemon._lfs_manifest:
                return JSONResponse({"ok": False, "error": "LFS not enabled"}, status_code=400)
            
            # 调用 daemon 的 process_large_files 方法
            daemon.process_large_files()
            
            return {"ok": True, "message": "Large files uploaded successfully"}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    
    @app.post("/sync/api/lfs/restore")
    def api_lfs_restore():
        """手动触发 LFS 文件恢复（从指针下载）"""
        try:
            if daemon is None:
                return JSONResponse({"ok": False, "error": "Daemon not available"}, status_code=503)
            
            if not daemon._lfs_api or not daemon._lfs_manifest:
                return JSONResponse({"ok": False, "error": "LFS not enabled"}, status_code=400)
            
            # 调用 daemon 的 restore_lfs_files 方法
            daemon.restore_lfs_files()
            
            return {"ok": True, "message": "LFS files restored successfully"}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)
    
    @app.get("/sync/api/lfs/list")
    def api_lfs_list():
        """列出所有被 LFS 管理的文件"""
        try:
            if daemon is None:
                return JSONResponse({"ok": False, "error": "Daemon not available"}, status_code=503)
            
            if not daemon._lfs_manifest:
                return JSONResponse({"ok": False, "error": "LFS not enabled"}, status_code=400)
            
            files = daemon._lfs_manifest.list_all_files()
            
            # 获取每个文件的详细信息
            file_info = []
            for file_path in files:
                record = daemon._lfs_manifest.get_file_record(file_path)
                if record:
                    current_ver = daemon._lfs_manifest.get_current_version(file_path)
                    file_info.append({
                        "path": file_path,
                        "current_hash": record.current_hash[:16] + "...",
                        "size": current_ver.size if current_ver else 0,
                        "version_count": len(record.versions),
                        "asset_name": current_ver.asset_name if current_ver else ""
                    })
            
            return {
                "ok": True,
                "files": file_info,
                "count": len(file_info)
            }
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 静态文件挂载必须在最后，避免拦截 API 路由
    web_dir = os.path.join(os.path.dirname(__file__), "web")
    if os.path.isdir(web_dir):
        # 静态页挂载到 /sync（但 API 路由优先级更高）
        app.mount("/sync", StaticFiles(directory=web_dir, html=True), name="web")

    return app


def serve(daemon=None) -> int:
    """启动 Uvicorn 服务，监听 0.0.0.0:5321。

    若缺少 fastapi/uvicorn 依赖，将打印提示并返回非零退出码。
    """
    # Lazy import uvicorn to keep deps light if serve not used
    try:
        import uvicorn  # type: ignore
    except Exception as e:
        err("缺少 uvicorn/fastapi 依赖，请在容器内或手动安装后再试：pip install fastapi uvicorn")
        return 1

    app = create_app(daemon=daemon)
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("SYNC_PORT", "5321")))
    return 0
