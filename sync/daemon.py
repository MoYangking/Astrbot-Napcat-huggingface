"""Sync Daemon
----------------
单进程守护：
1) 启动时确保仓库可用：初始化/设置远端/判断空仓/拉取并硬重置到远端分支；
2) 目录迁移与符号链接；空目录 .gitkeep 跟踪；提交并推送一次；
3) 启动文件监控（若安装 watchdog）；否则使用周期性扫描；
4) 循环任务：每 `SYNC_INTERVAL` 秒拉取(rebase)→提交→推送；出现文件事件时会尽快提交。

不再使用“就绪文件”判定是否完成；改为在启动阶段同步阻塞，直到：
- 远端可达，并完成 fetch；
- 本地 HEAD 与远端 `origin/<branch>` 对齐（通过 rev-parse 校验）。

环境变量：
- SYNC_INTERVAL（默认 180 秒）
"""

from __future__ import annotations

import os
import threading
import time
from typing import Optional

from sync.core import git_ops
from sync.core.blacklist import ensure_git_info_exclude
from sync.core.config import Settings, load_settings
from sync.core.linker import migrate_and_link, precreate_dirlike, track_empty_dirs
from sync.utils.logging import err, log


class SyncDaemon:
    """执行初始化、文件链接、空目录跟踪，并周期性同步到 GitHub 的守护进程。"""

    def __init__(self, settings: Optional[Settings] = None) -> None:
        self.st = settings or load_settings()
        self.interval = int(os.environ.get("SYNC_INTERVAL", "180"))
        self._event = threading.Event()  # 文件变更触发
        self._stop = threading.Event()
        self._lock = threading.Lock()  # 保护 git 操作的互斥
        self._last_commit_ts: float = 0.0

    # -------- 核心阶段：准备远端并对齐 HEAD --------
    def _remote_url(self) -> str:
        return f"https://x-access-token:{self.st.github_pat}@github.com/{self.st.github_repo}.git"

    def ensure_remote_ready(self) -> None:
        """阻塞直到远端可访问，且本地已拉取并对齐到远端分支。"""
        if not self.st.github_repo or not self.st.github_pat:
            raise RuntimeError("GITHUB_REPO/GITHUB_PAT 未配置")

        git_ops.ensure_repo(self.st.hist_dir, self.st.branch)
        ensure_git_info_exclude(self.st.hist_dir, self.st.excludes)
        git_ops.set_remote(self.st.hist_dir, self._remote_url())

        while not self._stop.is_set():
            try:
                # 远端是否为空？
                if git_ops.remote_is_empty(self.st.hist_dir):
                    log("远端为空：执行初始提交并推送")
                    git_ops.initial_commit_if_needed(self.st.hist_dir)
                    git_ops.push(self.st.hist_dir, self.st.branch)
                else:
                    git_ops.fetch_and_checkout(self.st.hist_dir, self.st.branch)

                # 校验 HEAD 对齐远端
                if self._head_matches_origin():
                    log("初始拉取完成且 HEAD 已对齐远端")
                    return
                else:
                    log("HEAD 未对齐远端，重试对齐...")
            except Exception as e:
                err(f"初始化/拉取失败：{e}")
            time.sleep(3)

    def _head_matches_origin(self) -> bool:
        """HEAD 与 origin/<branch> 是否一致。"""
        try:
            h1 = git_ops.run(["git", "rev-parse", "HEAD"], cwd=self.st.hist_dir).stdout.strip()
            h2 = git_ops.run(["git", "rev-parse", f"origin/{self.st.branch}"], cwd=self.st.hist_dir).stdout.strip()
            return h1 == h2 and bool(h1)
        except Exception:
            return False

    # -------- 迁移与链接、空目录跟踪 --------
    def link_and_track(self) -> None:
        log("预创建目录型目标")
        precreate_dirlike(self.st.hist_dir, self.st.targets)
        log("迁移并创建符号链接")
        migrate_and_link(self.st.base, self.st.hist_dir, self.st.targets)
        log("跟踪空目录并写入 .gitkeep")
        track_empty_dirs(self.st.hist_dir, self.st.targets, self.st.excludes)
        # 提交一次
        with self._lock:
            changed = git_ops.add_all_and_commit_if_needed(
                self.st.hist_dir, "chore(sync): initial link & empty dirs"
            )
            if changed:
                try:
                    git_ops.push(self.st.hist_dir, self.st.branch)
                except Exception as e:
                    err(f"初次推送失败（忽略）：{e}")

    # -------- 同步循环 --------
    def pull_commit_push(self) -> None:
        """一次完整的同步周期：先拉取(rebase)，再提交，再推送。"""
        with self._lock:
            # 尝试变基拉取以避免分叉
            git_ops.run(["git", "pull", "--rebase", "origin", self.st.branch], cwd=self.st.hist_dir, check=False)
            changed = git_ops.add_all_and_commit_if_needed(
                self.st.hist_dir, "chore(sync): periodic commit"
            )
            # 若有变更或远端领先，尝试推送
            try:
                git_ops.run(["git", "push", "origin", self.st.branch], cwd=self.st.hist_dir, check=False)
                if changed:
                    log("已提交并推送变更")
            except Exception as e:
                err(f"推送失败：{e}")
        self._last_commit_ts = time.time()

    # -------- 文件监控（可选 watchdog） --------
    def _watch_thread(self) -> None:
        """尝试使用 watchdog 监听 hist_dir（排除 .git）; 失败则不启用。"""
        try:
            from watchdog.events import FileSystemEventHandler  # type: ignore
            from watchdog.observers import Observer  # type: ignore

            class Handler(FileSystemEventHandler):
                def __init__(self, outer: SyncDaemon) -> None:
                    self.outer = outer

                def on_any_event(self, event):  # noqa: N802
                    # 忽略 .git 目录内的事件
                    if "/.git/" in event.src_path.replace("\\", "/"):
                        return
                    # 触发一次同步
                    self.outer._event.set()

            obs = Observer()
            obs.schedule(Handler(self), path=self.st.hist_dir, recursive=True)
            obs.start()
            log("已启动 watchdog 文件监控")
            try:
                while not self._stop.is_set():
                    time.sleep(1)
            finally:
                obs.stop()
                obs.join(timeout=5)
        except Exception as e:
            err(f"watchdog 不可用，使用定时扫描：{e}")

    # -------- 主循环 --------
    def run(self) -> int:
        log("启动 sync 守护进程…")
        # 1) 远端准备并对齐
        self.ensure_remote_ready()
        # 2) 链接与空目录跟踪
        self.link_and_track()

        # 3) 启动监控线程（可选）
        t = threading.Thread(target=self._watch_thread, daemon=True)
        t.start()

        # 4) 周期性同步（同时响应事件触发）
        while not self._stop.is_set():
            # 事件触发：尽快同步，但做一个最小间隔防抖
            if self._event.is_set():
                self._event.clear()
                if time.time() - self._last_commit_ts >= 5:
                    self.pull_commit_push()

            # 周期性同步
            self.pull_commit_push()
            # 睡眠间隔内，若出现事件则提前醒来
            for _ in range(self.interval):
                if self._stop.is_set():
                    break
                if self._event.is_set():
                    break
                time.sleep(1)
        return 0


def run_daemon() -> int:
    """入口函数：创建并运行守护进程。"""
    return SyncDaemon().run()

