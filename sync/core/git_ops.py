from __future__ import annotations

"""Git 子进程操作封装

职责：
- 初始化仓库、设置远端、判断远端空仓；
- 拉取并对齐到远端分支（含默认分支探测）；
- add/commit/push 常用操作与简单的状态检测。

所有函数通过 `subprocess.run` 调用系统 git，避免引入额外依赖。
失败时抛出 `GitError`（除非显式 `check=False`）。
"""

import os
import subprocess
from typing import List, Optional

from sync.utils.logging import log, err, mask_token


class GitError(RuntimeError):
    pass


def run(cmd: List[str], cwd: Optional[str] = None, check: bool = True) -> subprocess.CompletedProcess:
    """运行子进程命令。

    - cmd: 命令及参数列表；
    - cwd: 工作目录；
    - check: True 时非零退出码将抛出 `GitError`。
    返回 CompletedProcess。
    """
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and proc.returncode != 0:
        raise GitError(f"Command failed: {' '.join(cmd)}\nstdout: {proc.stdout}\nstderr: {proc.stderr}")
    return proc


def ensure_repo(hist_dir: str, branch: str) -> None:
    """确保 `hist_dir` 已初始化为 Git 仓库，并设置为安全目录。"""
    os.makedirs(hist_dir, exist_ok=True)
    if not os.path.isdir(os.path.join(hist_dir, ".git")):
        log(f"Initializing git repo at {hist_dir}")
        run(["git", "init", "-b", branch], cwd=hist_dir)
    # safety config
    try:
        run(["git", "config", "--global", "--add", "safe.directory", hist_dir], cwd=hist_dir, check=False)
    except Exception:
        pass
    # Ensure commit identity (local repo scope) and rebase policy
    name = os.environ.get("GIT_USER_NAME", "sync-bot")
    email = os.environ.get("GIT_USER_EMAIL", "sync-bot@local")
    run(["git", "config", "user.name", name], cwd=hist_dir, check=False)
    run(["git", "config", "user.email", email], cwd=hist_dir, check=False)
    run(["git", "config", "pull.rebase", "true"], cwd=hist_dir, check=False)


def set_remote(hist_dir: str, url: str) -> None:
    """设置或更新 origin 远端 URL（不会输出敏感 Token 到日志）。"""
    url_masked = mask_token(url)
    # add or update origin
    remotes = run(["git", "remote"], cwd=hist_dir).stdout.strip().splitlines()
    if "origin" in remotes:
        log(f"Set origin to {url_masked}")
        run(["git", "remote", "set-url", "origin", url], cwd=hist_dir)
    else:
        log(f"Add origin {url_masked}")
        run(["git", "remote", "add", "origin", url], cwd=hist_dir)


def remote_is_empty(hist_dir: str) -> bool:
    """远端是否为空仓（无 heads 且无任何 refs）。"""
    # No heads and no refs means empty
    heads = run(["git", "ls-remote", "--heads", "origin"], cwd=hist_dir, check=False).stdout.strip()
    all_refs = run(["git", "ls-remote", "origin"], cwd=hist_dir, check=False).stdout.strip()
    return len(heads) == 0 and len(all_refs) == 0


def fetch_and_checkout(hist_dir: str, branch: str) -> None:
    """fetch 远端并将工作区对齐到目标分支（或远端默认分支）。"""
    # Fetch; if branch not present, fall back to remote HEAD
    run(["git", "fetch", "--depth=1", "origin"], cwd=hist_dir)
    # Try target branch first
    ref_ok = run(["git", "rev-parse", f"origin/{branch}"], cwd=hist_dir, check=False).returncode == 0
    if ref_ok:
        run(["git", "checkout", "-B", branch], cwd=hist_dir)
        run(["git", "reset", "--hard", f"origin/{branch}"], cwd=hist_dir)
        return
    # fallback: read HEAD symref to find default branch
    head = run(["git", "ls-remote", "--symref", "origin", "HEAD"], cwd=hist_dir, check=False).stdout
    default_branch = branch
    for line in head.splitlines():
        if line.startswith("ref:"):
            default_branch = line.split()[1].split("/")[-1]
            break
    run(["git", "fetch", "--depth=1", "origin", default_branch], cwd=hist_dir)
    run(["git", "checkout", "-B", default_branch], cwd=hist_dir)
    run(["git", "reset", "--hard", f"origin/{default_branch}"], cwd=hist_dir)


def initial_commit_if_needed(hist_dir: str) -> None:
    """若仓库尚无提交，写入一个最小 README 并提交。"""
    # Create a minimal file if repo is empty
    status = run(["git", "rev-parse", "--verify", "HEAD"], cwd=hist_dir, check=False)
    if status.returncode != 0:
        readme = os.path.join(hist_dir, "README.md")
        if not os.path.exists(readme):
            with open(readme, "w", encoding="utf-8") as f:
                f.write("This repository is initialized by sync.\n")
        run(["git", "add", "-A"], cwd=hist_dir)
        run(["git", "commit", "-m", "chore(sync): initial commit"], cwd=hist_dir)


def push(hist_dir: str, branch: str) -> None:
    """执行 `git push -u origin <branch>`。"""
    run(["git", "push", "-u", "origin", branch], cwd=hist_dir)


def add_all_and_commit_if_needed(hist_dir: str, message: str) -> bool:
    """`git add -A` 后，仅当“索引中存在变更”才提交。

    说明：有些情况下 `git status --porcelain` 可能显示“工作区未暂存变更”，
    这会导致直接 `git commit` 报错。为避免守护进程崩溃，改为检测索引差异：
    使用 `git diff --cached --quiet` 的退出码判断是否有暂存变更（1 表示有差异）。

    返回：是否进行了提交。
    """
    run(["git", "add", "-A"], cwd=hist_dir, check=False)
    # 0 表示没有差异；1 表示存在差异；其他码为错误
    proc = run(["git", "diff", "--cached", "--quiet"], cwd=hist_dir, check=False)
    if proc.returncode == 1:
        run(["git", "commit", "-m", message], cwd=hist_dir)
        return True
    elif proc.returncode == 0:
        return False
    else:
        # diff 命令异常，保守起见不提交
        return False
