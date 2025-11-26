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

import json
import os
import subprocess
import threading
import time
from typing import Optional

from sync.core import git_ops
from sync.core.blacklist import ensure_git_info_exclude
from sync.core.config import Settings, load_settings
from sync.core.linker import migrate_and_link, precreate_dirlike, track_empty_dirs
from sync.utils.logging import err, log

# LFS imports (延迟导入，避免循环依赖)
try:
    from sync.core.lfs_ops import (
        restore_all_lfs_files,
        scan_large_files,
        convert_to_lfs,
        scan_pointer_files,
        restore_from_lfs
    )
    from sync.core.pointer import read_pointer
    from sync.core.release_api import GitHubReleaseAPI
    from sync.core.manifest import Manifest
    LFS_AVAILABLE = True
except ImportError as e:
    LFS_AVAILABLE = False
    log(f"LFS not available: {e}")


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
        
        # LFS 支持
        self._lfs_api: Optional[GitHubReleaseAPI] = None
        self._lfs_manifest: Optional[Manifest] = None
        if self.st.lfs_enabled and LFS_AVAILABLE:
            try:
                self._lfs_api = GitHubReleaseAPI(self.st.github_repo, self.st.github_pat)
                self._lfs_manifest = Manifest(self.st.hist_dir, self.st.lfs_release_tag)
                log("LFS enabled")
            except Exception as e:
                err(f"Failed to initialize LFS: {e}")
                self._lfs_api = None
                self._lfs_manifest = None

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
                
                # 修正文件权限：将 /home/user/ 下所有文件设为 777
                log("修正文件权限...")
                try:
                    subprocess.run(["chmod", "-R", "777", "/home/user"], check=False)
                except Exception as e:
                    err(f"修正权限失败: {e}")

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
    
    # -------- 进度管理 --------
    def write_progress(self, progress: dict) -> None:
        """写入同步进度到文件（供 Nginx 状态页读取）"""
        try:
            # 确保目录存在
            progress_dir = os.path.dirname(self.st.sync_progress_file)
            if progress_dir:
                os.makedirs(progress_dir, exist_ok=True)
            
            with open(self.st.sync_progress_file, 'w', encoding='utf-8') as f:
                json.dump(progress, f, indent=2)
        except Exception as e:
            err(f"Failed to write progress: {e}")
    
    def mark_sync_complete(self) -> None:
        """标记同步完成，允许其他服务启动"""
        try:
            with open(self.st.sync_complete_file, 'w') as f:
                f.write(str(int(time.time())))
            log("✓ Sync completed, other services can start")
            self.write_progress({"stage": "complete", "progress": 100})
        except Exception as e:
            err(f"Failed to mark sync complete: {e}")
    
    # -------- LFS 恢复 --------
    def restore_lfs_files(self) -> None:
        """恢复所有 LFS 文件（从指针文件下载实际文件）"""
        if not self.st.lfs_enabled or not self._lfs_api or not self._lfs_manifest:
            log("LFS not enabled or not available, skipping LFS restore")
            return
        
        log("Stage: Restoring LFS files...")
        self.write_progress({"stage": "lfs_download", "progress": 50, "current": 0, "total": 0})
        
        def progress_callback(completed: int, total: int):
            progress_pct = 50 + int((completed / total) * 45) if total > 0 else 50
            self.write_progress({
                "stage": "lfs_download",
                "progress": progress_pct,
                "current": completed,
                "total": total
            })
        
        try:
            results = restore_all_lfs_files(
                self.st.hist_dir,
                self._lfs_api,
                self._lfs_manifest,
                max_workers=self.st.lfs_max_workers,
                progress_callback=progress_callback
            )
            
            success_count = sum(1 for v in results.values() if v)
            total_count = len(results)
            
            if total_count > 0:
                log(f"LFS restore completed: {success_count}/{total_count} files")
            else:
                log("No LFS files to restore")
            
            self.write_progress({"stage": "lfs_download", "progress": 95})
        except Exception as e:
            err(f"LFS restore failed: {e}")
            # 继续执行，不阻止启动

    # -------- LFS 上传 --------
    def process_large_files(self) -> None:
        """扫描并处理大文件（转换为 LFS）"""
        if not self.st.lfs_enabled or not self._lfs_api or not self._lfs_manifest:
            return
        
        try:
            # 扫描所有目标目录中的大文件
            large_files = scan_large_files(
                self.st.hist_dir,
                self.st.lfs_threshold,
                self.st.excludes
            )
            
            if not large_files:
                return
            
            log(f"Found {len(large_files)} large files (>{self.st.lfs_threshold} bytes)")
            
            # 逐个转换为 LFS
            for file_path in large_files:
                try:
                    log(f"Converting to LFS: {os.path.relpath(file_path, self.st.hist_dir)}")
                    convert_to_lfs(
                        file_path,
                        self._lfs_api,
                        self._lfs_manifest,
                        self.st.lfs_release_tag
                    )
                except Exception as e:
                    err(f"Failed to convert {file_path} to LFS: {e}")
            
            # 清理旧版本（每个文件保留最多 N 个版本）
            log("Cleaning up old LFS versions...")
            to_delete = self._lfs_manifest.cleanup_all_old_versions(keep=self.st.lfs_max_versions)
            
            # 从 Release 删除旧版本的 assets
            if to_delete:
                release = self._lfs_api.get_or_create_release(self.st.lfs_release_tag)
                for file_path, asset_names in to_delete.items():
                    for asset_name in asset_names:
                        try:
                            asset = self._lfs_api.get_asset_by_name(release, asset_name)
                            if asset:
                                self._lfs_api.delete_asset(asset)
                        except Exception as e:
                            err(f"Failed to delete old asset {asset_name}: {e}")
            
            # 保存 manifest
            self._lfs_manifest.save()
            
        except Exception as e:
            err(f"Failed to process large files: {e}")
    
    # -------- 同步循环 --------
    def pull_commit_push(self) -> None:
        """一次完整的同步周期：先拉取(rebase)，立即恢复LFS，再检测大文件，再提交，再推送。

        - 使用 `git pull --rebase` 尽量维持线性历史；
        - pull 后立即恢复 LFS 文件（防止被删除）；
        - 扫描并转换大文件为 LFS（如果启用）；
        - 检测有变更才提交；
        - push 失败并不会中断守护，仅记录日志等待下次重试。
        """
        with self._lock:
            # 1. 尝试变基拉取以避免分叉
            git_ops.run(["git", "pull", "--rebase", "origin", self.st.branch], cwd=self.st.hist_dir, check=False)
            
            # 修正文件权限：确保所有文件都可被非 root 进程访问
            try:
                subprocess.run(["chmod", "-R", "777", "/home/user"], check=False)
            except Exception as e:
                err(f"修正权限失败: {e}")
            
            # 2. 立即恢复 LFS 文件（防止 pull 删除大文件）
            if self.st.lfs_enabled and self._lfs_api and self._lfs_manifest:
                try:
                    # 扫描指针文件
                    from sync.core.lfs_ops import scan_pointer_files
                    from sync.core.pointer import read_pointer
                    
                    pointers = scan_pointer_files(self.st.hist_dir)
                    if pointers:
                        log(f"Found {len(pointers)} pointer files after pull, checking...")
                        for pointer_path in pointers:
                            try:
                                pointer = read_pointer(pointer_path)
                                if not pointer:
                                    log(f"Skipping invalid pointer: {pointer_path}")
                                    continue
                                
                                # 检查实际文件是否存在
                                actual_path = pointer_path[:-8] if pointer_path.endswith('.pointer') else pointer_path
                                if not os.path.exists(actual_path):
                                    # 文件不存在，可能被 pull 删除了，立即恢复
                                    log(f"Restoring file deleted by pull: {os.path.basename(actual_path)}")
                                    restore_from_lfs(pointer_path, self._lfs_api, self._lfs_manifest, verify_hash=False)
                            except Exception as e:
                                err(f"Failed to restore {pointer_path}: {e}")
                                continue
                except Exception as e:
                    err(f"Failed to restore LFS files after pull: {e}")
            
            # 3. 处理大文件（转换为 LFS）
            self.process_large_files()
            
            # 3. 持续跟踪空目录，确保新建的空文件夹也能被同步
            track_empty_dirs(self.st.hist_dir, self.st.targets, self.st.excludes)
            
            # 4. 提交变更（包括新的指针文件和 manifest）
            changed = git_ops.add_all_and_commit_if_needed(
                self.st.hist_dir, "chore(sync): periodic commit"
            )
            
            # 5. 若有变更或远端领先，尝试推送
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
        
        # 写入初始进度
        self.write_progress({"stage": "starting", "progress": 0})
        
        # 1) 远端准备并对齐（Git 同步）
        log("Stage 1/4: Git repository sync...")
        self.write_progress({"stage": "git", "progress": 10})
        self.ensure_remote_ready()
        
        # 确保 HEAD 完全对齐后再继续
        log("Verifying Git HEAD alignment...")
        max_retries = 10
        for i in range(max_retries):
            if self._head_matches_origin():
                log("✓ Git HEAD aligned with remote")
                break
            log(f"Waiting for HEAD alignment... ({i+1}/{max_retries})")
            time.sleep(2)
        else:
            err("Failed to align Git HEAD, but continuing...")
        
        self.write_progress({"stage": "git", "progress": 25})
        
        # 2) 链接与空目录跟踪
        log("Stage 2/4: Creating symlinks and tracking empty dirs...")
        self.write_progress({"stage": "linking", "progress": 30})
        self.link_and_track()
        self.write_progress({"stage": "linking", "progress": 50})
        
        # 3) 恢复 LFS 文件
        log("Stage 3/4: Restoring LFS files...")
        self.restore_lfs_files()
        
        # 4) 标记同步完成
        log("Stage 4/4: Finalizing...")
        self.mark_sync_complete()
        
        # 5) 进入周期同步循环
        log("Entering periodic sync loop...")
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
