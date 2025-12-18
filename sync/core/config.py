"""配置与路径映射

职责：
- 读取环境变量（GITHUB_PAT/GITHUB_REPO/HIST_DIR/GIT_BRANCH/SYNC_TARGETS/EXCLUDE_PATHS）。
- 从 `HIST_DIR/sync-config.json` 读取目标与黑名单覆盖项（若存在）。
- 提供路径映射工具：
  - `to_abs_under_base(base, rel)`: BASE 相对路径 → 绝对路径；
  - `to_under_hist(hist, rel)`: BASE 相对路径 → 历史仓库下的镜像路径。
"""

import os
from dataclasses import dataclass
from typing import List, Dict, Any


DEFAULT_BASE = os.environ.get("BASE", "/")
DEFAULT_HIST_DIR = os.environ.get("HIST_DIR", "/home/user/.astrbot-backup")
DEFAULT_BRANCH = os.environ.get("GIT_BRANCH", "main")

# Targets are relative to BASE; mirrors under HIST_DIR preserving path components
# Directories should end with / to distinguish from files
DEFAULT_TARGETS = (
    os.environ.get(
        "SYNC_TARGETS",
        " ".join(
            [
                "home/user/AstrBot/data/",
                "home/user/config/",
                "app/napcat/config/",
                "home/user/nginx/admin_config.json",
                "app/.config/QQ/",
                "home/user/filebrowser-data/filebrowser.db",
            ]
        ),
    )
    .strip()
    .split()
)


# Blacklist paths are relative to HIST_DIR root, e.g.
#   home/user/AstrBot/data/plugin_data/jm_cosmos
DEFAULT_EXCLUDES = (
    os.environ.get(
        "EXCLUDE_PATHS",
        "home/user/AstrBot/data/plugin_data/jm_cosmos home/user/AstrBot/data/memes_data",
    )
    .strip()
    .split()
)

# 系统文件强制排除（无论用户如何配置都会排除）
SYSTEM_EXCLUDES = [
    ".sync-complete",
    ".sync-progress.json",
    ".sync.ready",
]

# LFS 配置
DEFAULT_LFS_ENABLED = os.environ.get("LFS_ENABLED", "true").lower() == "true"
DEFAULT_LFS_THRESHOLD = int(os.environ.get("LFS_THRESHOLD", str(60 * 1024 * 1024)))  # 默认 60MB
DEFAULT_LFS_RELEASE_TAG = os.environ.get("LFS_RELEASE_TAG", "large-files-v1")
DEFAULT_LFS_MAX_VERSIONS = int(os.environ.get("LFS_MAX_VERSIONS", "3"))  # 每个文件最多保留 3 个版本
DEFAULT_LFS_MAX_WORKERS = int(os.environ.get("LFS_MAX_WORKERS", "3"))  # 并发下载/上传数


@dataclass
class Settings:
    base: str
    hist_dir: str
    branch: str
    github_pat: str
    github_repo: str
    targets: List[str]
    excludes: List[str]
    ready_file: str  # 为兼容保留（守护进程不依赖此项）
    # LFS 配置
    lfs_enabled: bool
    lfs_threshold: int
    lfs_release_tag: str
    lfs_max_versions: int
    lfs_max_workers: int
    sync_complete_file: str  # 同步完成标记文件
    sync_progress_file: str  # 同步进度文件


def _load_file_overrides(hist_dir: str) -> Dict[str, Any]:
    """从 `HIST_DIR/sync-config.json` 读取覆盖项（若存在）。

    返回一个 dict，可包含：
    - targets: List[str]
    - excludes: List[str]
    任何异常或不存在时返回空对象。
    """
    import json

    cfg_path = os.path.join(hist_dir, "sync-config.json")
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            obj = json.load(f)
            if isinstance(obj, dict):
                return obj
    except FileNotFoundError:
        pass
    except Exception:
        pass
    return {}


def save_file_overrides(hist_dir: str, data: Dict[str, Any]) -> None:
    """写入覆盖项到 `HIST_DIR/sync-config.json`。

    参数 data 应包含 `targets` 与/或 `excludes`。
    """
    import json

    os.makedirs(hist_dir, exist_ok=True)
    cfg_path = os.path.join(hist_dir, "sync-config.json")
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_settings() -> Settings:
    """加载运行时配置。

    优先级：环境变量默认值 → 文件覆盖（仅 targets/excludes）。
    返回 Settings 数据类实例。
    """
    base = DEFAULT_BASE.rstrip("/") or "/"
    hist_dir = os.path.abspath(DEFAULT_HIST_DIR)
    branch = DEFAULT_BRANCH

    github_pat = os.environ.get("GITHUB_PAT", "")
    github_repo = os.environ.get("GITHUB_REPO", "")  # owner/repo

    targets = list(DEFAULT_TARGETS)
    excludes = list(DEFAULT_EXCLUDES)

    # 覆盖：从文件读取 targets/excludes
    overrides = _load_file_overrides(hist_dir)
    if isinstance(overrides.get("targets"), list) and overrides["targets"]:
        targets = [str(x).lstrip("/") for x in overrides["targets"] if str(x).strip()]
    if isinstance(overrides.get("excludes"), list):
        ex = [str(x).strip("/") for x in overrides["excludes"] if str(x).strip()]
        if ex:
            excludes = ex
    
    # 强制添加系统排除项（无论用户如何配置）
    for sys_ex in SYSTEM_EXCLUDES:
        if sys_ex not in excludes:
            excludes.append(sys_ex)

    ready_file = os.environ.get("SYNC_READY_FILE", os.path.join(hist_dir, ".sync.ready"))
    
    # LFS 配置
    lfs_enabled = DEFAULT_LFS_ENABLED
    lfs_threshold = DEFAULT_LFS_THRESHOLD
    lfs_release_tag = DEFAULT_LFS_RELEASE_TAG
    lfs_max_versions = DEFAULT_LFS_MAX_VERSIONS
    lfs_max_workers = DEFAULT_LFS_MAX_WORKERS
    
    sync_complete_file = os.path.join(hist_dir, ".sync-complete")
    sync_progress_file = os.path.join(hist_dir, ".sync-progress.json")

    return Settings(
        base=base,
        hist_dir=hist_dir,
        branch=branch,
        github_pat=github_pat,
        github_repo=github_repo,
        targets=targets,
        excludes=excludes,
        ready_file=ready_file,
        lfs_enabled=lfs_enabled,
        lfs_threshold=lfs_threshold,
        lfs_release_tag=lfs_release_tag,
        lfs_max_versions=lfs_max_versions,
        lfs_max_workers=lfs_max_workers,
        sync_complete_file=sync_complete_file,
        sync_progress_file=sync_progress_file,
    )


def to_abs_under_base(base: str, rel: str) -> str:
    """将 BASE 相对路径转换为绝对路径。
    例如 base='/'，rel='home/user/AstrBot/data' → '/home/user/AstrBot/data'
    若 rel 本身为绝对路径，则直接返回。
    """
    if rel.startswith("/"):
        # If user passes absolute, honor it
        return rel
    if base == "/":
        return "/" + rel
    return os.path.normpath(os.path.join(base, rel))


def to_under_hist(hist: str, rel: str) -> str:
    """将 BASE 相对路径映射到历史仓库内部同结构路径。
    例如 hist='/home/user/.astrbot-backup'，rel='home/user/AstrBot/data'
    → '/home/user/.astrbot-backup/home/user/AstrBot/data'
    """
    rel = rel.lstrip("/")
    return os.path.normpath(os.path.join(hist, rel))
