from __future__ import annotations

"""Git 子进程操作封装

职责：
- 初始化仓库、设置远端、判断远端空仓
- 拉取并对齐到远端分支
- add/commit/push 常用操作
"""

import os
import subprocess
from typing import List, Optional

from sync.utils.logging import log, err, mask_token


class GitError(RuntimeError):
    pass


def run(cmd: List[str], cwd: Optional[str] = None, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and proc.returncode != 0:
        raise GitError(f"Command failed: {' '.join(cmd)}\nstdout: {proc.stdout}\nstderr: {proc.stderr}")
    return proc


def ensure_repo(hist_dir: str, branch: str) -> None:
    os.makedirs(hist_dir, exist_ok=True)
    if not os.path.isdir(os.path.join(hist_dir, ".git")):
        log(f"Initializing git repo at {hist_dir}")
        run(["git", "init", "-b", branch], cwd=hist_dir)
    # safety config
    try:
        run(["git", "config", "--global", "--add", "safe.directory", hist_dir], cwd=hist_dir, check=False)
    except Exception:
        pass


def set_remote(hist_dir: str, url: str) -> None:
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
    # No heads and no refs means empty
    heads = run(["git", "ls-remote", "--heads", "origin"], cwd=hist_dir, check=False).stdout.strip()
    all_refs = run(["git", "ls-remote", "origin"], cwd=hist_dir, check=False).stdout.strip()
    return len(heads) == 0 and len(all_refs) == 0


def fetch_and_checkout(hist_dir: str, branch: str) -> None:
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
    run(["git", "push", "-u", "origin", branch], cwd=hist_dir)


def add_all_and_commit_if_needed(hist_dir: str, message: str) -> bool:
    run(["git", "add", "-A"], cwd=hist_dir)
    diff = run(["git", "status", "--porcelain"], cwd=hist_dir).stdout.strip()
    if diff:
        run(["git", "commit", "-m", message], cwd=hist_dir)
        return True
    return False
