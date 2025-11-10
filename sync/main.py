"""统一入口：守护进程 + Web 服务

启动后：
- 后台线程运行同步守护（自动初始化/拉取/链接/周期提交）
- 主线程运行 Web 管理页面（端口 5321，前缀 /sync）
"""

from __future__ import annotations

import threading

from sync.daemon import SyncDaemon
from sync.server import serve


def run_all() -> int:
    daemon = SyncDaemon()
    t = threading.Thread(target=daemon.run, daemon=True)
    t.start()
    # 在主线程启动 Web 服务，带上 daemon 句柄以提供“立即同步”等操作
    return serve(daemon=daemon)

