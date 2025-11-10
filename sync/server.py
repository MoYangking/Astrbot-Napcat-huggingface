from __future__ import annotations

"""最小管理 API/页面（可选）
不依赖于守护逻辑运行；仅提供状态查询与一次性初始化操作的触发。
"""

import os
from typing import Dict

from sync.core import git_ops
from sync.core.blacklist import ensure_git_info_exclude
from sync.core.config import load_settings, save_file_overrides
from sync.core.linker import migrate_and_link, precreate_dirlike, track_empty_dirs
from sync.utils.logging import log, err


def _remote_url(pat: str, repo: str) -> str:
    return f"https://x-access-token:{pat}@github.com/{repo}.git"


def create_app(daemon=None):
    # Lazy import to avoid hard dependency when not serving
    from fastapi import FastAPI
    from fastapi.staticfiles import StaticFiles
    from fastapi.responses import JSONResponse

    app = FastAPI(title="Sync Manager", version="0.2.0")

    web_dir = os.path.join(os.path.dirname(__file__), "web")
    if os.path.isdir(web_dir):
        # 静态页与 API 统一前缀 /sync
        app.mount("/sync", StaticFiles(directory=web_dir, html=True), name="web")

    @app.get("/sync/api/status")
    def api_status() -> Dict:
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
        try:
            st = load_settings()
            git_ops.run(["git", "pull", "--rebase", "origin", st.branch], cwd=st.hist_dir, check=False)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 仅推送
    @app.post("/sync/api/push")
    def api_push():
        try:
            st = load_settings()
            git_ops.run(["git", "push", "origin", st.branch], cwd=st.hist_dir, check=False)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    # 重新链接并跟踪空目录
    @app.post("/sync/api/relink")
    def api_relink():
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
        st = load_settings()
        return {"targets": st.targets}

    @app.post("/sync/api/targets")
    def api_set_targets(payload: dict):
        try:
            st = load_settings()
            data = {"targets": payload.get("targets", st.targets), "excludes": st.excludes}
            save_file_overrides(st.hist_dir, data)
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    @app.get("/sync/api/excludes")
    def api_get_excludes():
        st = load_settings()
        return {"excludes": st.excludes}

    @app.post("/sync/api/excludes")
    def api_set_excludes(payload: dict):
        try:
            st = load_settings()
            data = {"targets": st.targets, "excludes": payload.get("excludes", st.excludes)}
            save_file_overrides(st.hist_dir, data)
            ensure_git_info_exclude(st.hist_dir, data["excludes"])
            return {"ok": True}
        except Exception as e:
            return JSONResponse({"ok": False, "error": str(e)}, status_code=500)

    return app


def serve(daemon=None) -> int:
    # Lazy import uvicorn to keep deps light if serve not used
    try:
        import uvicorn  # type: ignore
    except Exception as e:
        err("缺少 uvicorn/fastapi 依赖，请在容器内或手动安装后再试：pip install fastapi uvicorn")
        return 1

    app = create_app(daemon=daemon)
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("SYNC_PORT", "5321")))
    return 0
