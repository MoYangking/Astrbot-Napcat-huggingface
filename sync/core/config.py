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
                "home/user/gemini-data/",
                "home/user/gemini-balance-main/.env",
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

    ready_file = os.environ.get("SYNC_READY_FILE", os.path.join(hist_dir, ".sync.ready"))

    return Settings(
        base=base,
        hist_dir=hist_dir,
        branch=branch,
        github_pat=github_pat,
        github_repo=github_repo,
        targets=targets,
        excludes=excludes,
        ready_file=ready_file,
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
