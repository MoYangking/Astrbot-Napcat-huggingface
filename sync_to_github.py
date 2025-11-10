#!/usr/bin/env python3
"""同步服务启动器

直接运行即可进入全自动模式：守护进程 + Web 管理（端口 5321，前缀 /sync）。
"""
from sync.main import run_all


if __name__ == "__main__":
    raise SystemExit(run_all())
