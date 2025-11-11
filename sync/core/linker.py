from __future__ import annotations

"""迁移与符号链接

职责：
- 将 BASE 下的目标（目录/文件）迁移到历史仓库 hist_dir 下对应路径；
- 在原路径创建指向历史仓库的符号链接；
- 若原路径缺失：目录进行预创建；“看起来像文件”的目标则创建空文件以被 Git 跟踪。

冲突处理（当前策略）：
- 目录：合并复制（`rsync -a` 或逐文件复制）到目标目录，不覆盖已存在文件；然后删除原目录并建立符号链接。
- 文件：若目标已存在则删除原文件，仅保留目标；随后在原路径建立符号链接（即“以远端为准”）。
"""

import os
import shutil
import subprocess
from typing import Iterable

from sync.core.blacklist import is_excluded
from sync.core.config import to_abs_under_base, to_under_hist
from sync.utils.logging import log


def _rsync_available() -> bool:
    return shutil.which("rsync") is not None


def ensure_symlink(src: str, dst: str) -> None:
    """确保 `src` 是指向 `dst` 的符号链接。

    - 若 src 已是软链但目标不同，则替换之；
    - 若 src 存在（文件/目录），先移除再创建软链；
    - 父目录若不存在则自动创建。
    """
    parent = os.path.dirname(src)
    if parent:
        log(f"确保父目录存在: {parent}")
        os.makedirs(parent, exist_ok=True)
    
    if os.path.islink(src):
        cur = os.readlink(src)
        if cur == dst:
            log(f"符号链接已存在且正确: {src} -> {dst}")
            return
        log(f"更新符号链接 {src}: {cur} -> {dst}")
        os.unlink(src)
    elif os.path.exists(src):
        log(f"删除已存在的路径: {src} (isdir={os.path.isdir(src)})")
        if os.path.isdir(src):
            shutil.rmtree(src)
        else:
            os.remove(src)
    
    try:
        os.symlink(dst, src)
        log(f"✓ 符号链接已创建: {src} -> {dst}")
    except OSError as e:
        log(f"✗ 符号链接创建失败: {src} -> {dst}, 错误: {e}")
        raise



def migrate_and_link(base: str, hist_dir: str, rel_targets: Iterable[str]) -> None:
    """对目标列表执行“迁移并建立软链”。

    - base: 作为绝对路径根（通常为 `/`）；
    - hist_dir: 历史仓库根目录；
    - rel_targets: BASE 相对路径（例如 `home/user/AstrBot/data`）。
    """
    for rel in rel_targets:
        log(f"处理目标: {rel}")
        # Normalize: remove trailing slash for symlink paths
        rel_clean = rel.rstrip("/")
        src = to_abs_under_base(base, rel_clean)
        dst = to_under_hist(hist_dir, rel_clean)
        log(f"  src={src}, dst={dst}")
        os.makedirs(os.path.dirname(dst), exist_ok=True)

        if os.path.islink(src):
            log(f"  {src} 已是符号链接")
            ensure_symlink(src, dst)
            continue

        if os.path.isdir(src):
            log(f"  {src} 是目录，开始迁移")
            os.makedirs(dst, exist_ok=True)
            if _rsync_available():
                subprocess.run(["rsync", "-a", f"{src}/", f"{dst}/"], check=False)
            else:
                # copytree doesn't merge; copy files one by one preserving hierarchy
                for root, dirs, files in os.walk(src):
                    relp = os.path.relpath(root, src)
                    dstd = os.path.join(dst, relp) if relp != "." else dst
                    os.makedirs(dstd, exist_ok=True)
                    for fn in files:
                        s = os.path.join(root, fn)
                        t = os.path.join(dstd, fn)
                        if not os.path.exists(t):
                            shutil.copy2(s, t)
            # remove original and link
            log(f"  删除原目录: {src}")
            shutil.rmtree(src, ignore_errors=True)
            ensure_symlink(src, dst)
        elif os.path.isfile(src):
            log(f"  {src} 是文件，开始迁移")
            if not os.path.exists(dst):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.move(src, dst)
            else:
                # dst exists, drop src to avoid dup
                os.remove(src)
            ensure_symlink(src, dst)
        else:
            log(f"  {src} 不存在，创建空目标")
            # src missing; ensure dst exists (dir or empty file)
            # Use trailing slash to distinguish: path/ = directory, path = file
            if rel.endswith("/"):
                log(f"  是目录（以/结尾），创建空目录: {dst}")
                os.makedirs(dst, exist_ok=True)
            else:
                log(f"  是文件（无/结尾），创建空文件: {dst}")
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if not os.path.exists(dst):
                    open(dst, "a").close()
            ensure_symlink(src, dst)


def precreate_dirlike(hist_dir: str, rel_targets: Iterable[str]) -> None:
    """预创建目录型目标（以/结尾的路径）。"""
    for rel in rel_targets:
        rel_clean = rel.rstrip("/")
        dst = to_under_hist(hist_dir, rel_clean)
        if rel.endswith("/"):
            os.makedirs(dst, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)


def track_empty_dirs(hist_dir: str, rel_targets: Iterable[str], excludes: Iterable[str]) -> int:
    """扫描空目录并写入 `.gitkeep`，占位以确保 Git 跟踪。

    返回：写入的 `.gitkeep` 个数。
    """
    written = 0
    for rel in rel_targets:
        rel_clean = rel.rstrip("/")
        root = to_under_hist(hist_dir, rel_clean)
        if os.path.isdir(root):
            for d, subdirs, files in os.walk(root):
                rel_under_hist = os.path.relpath(d, hist_dir).lstrip("./")
                if is_excluded(rel_under_hist, excludes):
                    continue
                # skip .git
                if "/.git/" in f"/{rel_under_hist}/":
                    continue
                # empty dir: no files and no non-excluded subdirs containing files
                if not os.listdir(d):
                    keep = os.path.join(d, ".gitkeep")
                    if not os.path.exists(keep):
                        open(keep, "a").close()
                        written += 1
        # If target looks like a file and exists zero-size, keep as is; if not exists, create empty ensured in migrate
    return written
