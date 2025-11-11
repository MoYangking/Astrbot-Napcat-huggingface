"""Sync Daemon
----------------
单进程守护，覆盖从“首次初始化/拉取/对齐”到“目录迁移 + 软链”再到“持续同步”的全流程。

工作步骤（按启动顺序）：
1) 远端准备：保证本地历史仓库存在并配置好 origin；若远端为空则创建初始提交并推送；否则 fetch 落地。
2) HEAD 对齐：循环直到本地 `HEAD` 与 `origin/<branch>` 完全一致（用 `git rev-parse` 校验）。
3) 链接阶段：将 BASE 下的目标路径迁移到历史仓库，再在原路径创建符号链接；为空目录写入 `.gitkeep` 并提交一次。
4) 周期同步：固定周期（默认 180 秒）执行 pull --rebase → commit（如有）→ push。

关键特性：
- 不使用“就绪文件”这种间接信号；而是用 Git 的真实 HEAD 对比保证拉取完成再继续。
- 链接在拉取完成之后执行，避免“半拉取状态”破坏本地数据。

可调环境变量：
- SYNC_INTERVAL：周期同步间隔（秒），默认 180。
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
    """同步守护进程。

    - settings: 运行时配置，默认从环境和配置文件加载。
    - interval: 周期同步间隔（秒），ENV SYNC_INTERVAL 可覆盖。
    - _event/_stop: 线程通信事件；文件变更触发同步、停止标记。
    - _lock: 保护 Git 操作的互斥锁，避免并发 pull/commit/push。
    - _last_commit_ts: 上次提交/推送的时间戳，用于简单的防抖。
    """

    def __init__(self, settings: Optional[Settings] = None) -> None:
        self.st = settings or load_settings()
        self.interval = int(os.environ.get("SYNC_INTERVAL", "180"))
        self._stop = threading.Event()
        self._lock = threading.Lock()  # 保护 git 操作的互斥
        self._last_commit_ts: float = 0.0

    # -------- 核心阶段：准备远端并对齐 HEAD --------
    def _remote_url(self) -> str:
        return f"https://x-access-token:{self.st.github_pat}@github.com/{self.st.github_repo}.git"

    def ensure_remote_ready(self) -> None:
        """阻塞直到远端可访问，且本地已拉取并对齐到远端分支。

        行为：
        - 若远端为空，创建初始提交并推送。
        - 若远端已有内容，fetch 并 checkout + reset 到远端分支。
        - 校验本地/远端 HEAD 一致，才返回；否则 3s 后重试。
        """
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
        """HEAD 与 origin/<branch> 是否一致。

        返回 True 表示“拉取完成且本地已对齐远端”。
        失败或异常返回 False。
        """
        try:
            h1 = git_ops.run(["git", "rev-parse", "HEAD"], cwd=self.st.hist_dir).stdout.strip()
            h2 = git_ops.run(["git", "rev-parse", f"origin/{self.st.branch}"], cwd=self.st.hist_dir).stdout.strip()
            return h1 == h2 and bool(h1)
        except Exception:
            return False

    # -------- 迁移与链接、空目录跟踪 --------
    def link_and_track(self) -> None:
        """执行目录/文件迁移 + 符号链接、空目录跟踪和一次性提交推送。"""
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
        """一次完整的同步周期：先拉取(rebase)，再提交，再推送。

        - 使用 `git pull --rebase` 尽量维持线性历史；
        - 检测有变更才提交；
        - push 失败并不会中断守护，仅记录日志等待下次重试。
        """
        with self._lock:
            # 尝试变基拉取以避免分叉
            git_ops.run(["git", "pull", "--rebase", "origin", self.st.branch], cwd=self.st.hist_dir, check=False)
            # 持续跟踪空目录，确保新建的空文件夹也能被同步
            track_empty_dirs(self.st.hist_dir, self.st.targets, self.st.excludes)
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

    # -------- 主循环 --------
    def run(self) -> int:
        """主运行函数：按步骤拉起守护逻辑并进入循环。"""
        log("启动 sync 守护进程…")
        # 1) 远端准备并对齐
        self.ensure_remote_ready()
        # 2) 链接与空目录跟踪
        self.link_and_track()
        # 3) 仅按固定周期同步
        while not self._stop.is_set():
            self.pull_commit_push()
            for _ in range(self.interval):
                if self._stop.is_set():
                    break
                time.sleep(1)
        return 0


def run_daemon() -> int:
    """入口函数：创建并运行守护进程（供外部调用）。"""
    return SyncDaemon().run()
