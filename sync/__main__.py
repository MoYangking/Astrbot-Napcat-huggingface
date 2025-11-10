"""模块入口：直接 `python -m sync` 启动守护 + Web。"""

from .main import run_all


if __name__ == "__main__":
    raise SystemExit(run_all())
