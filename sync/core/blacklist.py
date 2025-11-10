from __future__ import annotations

"""黑名单：

职责：
- 基于“相对 HIST_DIR”的路径前缀匹配，用于排除提交；
- 将黑名单写入 `.git/info/exclude`，使 `git add -A` 自动忽略这些路径。
"""

import os
from typing import Iterable

from sync.utils.logging import log


def is_excluded(rel_under_hist: str, excludes: Iterable[str]) -> bool:
    """判断给定路径（相对 HIST_DIR）是否命中黑名单。

    前缀匹配（`a/b` 将命中 `a/b` 与其子路径）。
    """
    # Normalize and compare path-prefix-wise
    rel = rel_under_hist.strip("./")
    for ex in excludes:
        exn = ex.strip("./")
        if rel == exn or rel.startswith(exn + "/"):
            return True
    return False


def ensure_git_info_exclude(hist_dir: str, excludes: Iterable[str]) -> None:
    """确保 `.git/info/exclude` 中包含所有黑名单条目（幂等追加）。"""
    exfile = os.path.join(hist_dir, ".git", "info", "exclude")
    os.makedirs(os.path.dirname(exfile), exist_ok=True)
    try:
        existing: set[str] = set()
        if os.path.exists(exfile):
            with open(exfile, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    existing.add(line.rstrip("\n"))
        to_add = []
        for ex in excludes:
            ex = ex.strip()
            if ex and ex not in existing:
                to_add.append(ex)
        if to_add:
            with open(exfile, "a", encoding="utf-8") as f:
                for ex in to_add:
                    f.write(ex + "\n")
            log(f"Updated git info/exclude with {len(to_add)} entries")
    except Exception:
        # silently ignore
        pass
