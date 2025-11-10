"""统一入口：同时启动“同步守护进程 + Web 管理页面”。

运行效果：
- 后台线程运行同步守护：自动初始化/拉取/对齐、迁移与符号链接、空目录跟踪、周期提交推送；
- 主线程运行 Web 管理页面：端口 5321，前缀 `/sync`（包含状态展示和手动操作）。
"""

from __future__ import annotations

import threading

from sync.daemon import SyncDaemon
from sync.server import serve


def run_all() -> int:
    """拉起守护线程，并在主线程启动 Web 服务。"""
    daemon = SyncDaemon()
    t = threading.Thread(target=daemon.run, daemon=True)
    t.start()
    # 在主线程启动 Web 服务，带上 daemon 句柄以提供“立即同步”等操作
    return serve(daemon=daemon)
