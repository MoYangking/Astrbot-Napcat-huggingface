from __future__ import annotations

"""迁移与符号链接

- 将 BASE 路径下的目标迁移到历史仓库 hist_dir 下对应路径；
- 在原路径创建符号链接回到 hist_dir；
- 若源缺失：目录预创建；看起来是文件的项则创建空文件。
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
    os.makedirs(os.path.dirname(src), exist_ok=True)
    if os.path.islink(src):
        # update link target if needed
        cur = os.readlink(src)
        if cur != dst:
            try:
                os.unlink(src)
            except OSError:
                pass
            os.symlink(dst, src)
        return
    if os.path.exists(src):
        try:
            os.unlink(src)
        except OSError:
            if os.path.isdir(src):
                shutil.rmtree(src)
            else:
                os.remove(src)
    os.symlink(dst, src)


def migrate_and_link(base: str, hist_dir: str, rel_targets: Iterable[str]) -> None:
    for rel in rel_targets:
        src = to_abs_under_base(base, rel)
        dst = to_under_hist(hist_dir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)

        if os.path.islink(src):
            # Already a link, just ensure points to dst
            ensure_symlink(src, dst)
            continue

        if os.path.isdir(src):
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
            shutil.rmtree(src, ignore_errors=True)
            ensure_symlink(src, dst)
        elif os.path.isfile(src):
            if not os.path.exists(dst):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.move(src, dst)
            else:
                # dst exists, drop src to avoid dup
                os.remove(src)
            ensure_symlink(src, dst)
        else:
            # src missing; ensure dst exists (dir or empty file)
            # If rel path looks like a file (has extension or exists as file under dst), create empty file
            if rel.rstrip("/").split("/")[-1].count(".") >= 1:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if not os.path.exists(dst):
                    open(dst, "a").close()
            else:
                os.makedirs(dst, exist_ok=True)
            ensure_symlink(src, dst)


def precreate_dirlike(hist_dir: str, rel_targets: Iterable[str]) -> None:
    for rel in rel_targets:
        # consider those without ext as dirs
        name = rel.rstrip("/").split("/")[-1]
        looks_file = "." in name
        dst = to_under_hist(hist_dir, rel)
        if looks_file:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
        else:
            os.makedirs(dst, exist_ok=True)


def track_empty_dirs(hist_dir: str, rel_targets: Iterable[str], excludes: Iterable[str]) -> int:
    """扫描空目录并写入 .gitkeep，占位以确保 Git 跟踪。

    返回写入的 .gitkeep 数量。
    """
    written = 0
    for rel in rel_targets:
        root = to_under_hist(hist_dir, rel)
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
