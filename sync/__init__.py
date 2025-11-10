"""Sync 包：本地到 GitHub 的自动同步工具集。

推荐直接运行：
  `python -m sync`  → 启动守护进程（全自动）并开启 Web 管理页面。

包含模块：
- `sync.daemon`：守护进程核心逻辑（初始化/拉取/链接/周期同步）。
- `sync.server`：最小 Web API 与静态页面（前缀 `/sync`，端口 5321）。
- `sync.core.*`：配置、Git 操作、链接与黑名单等基础组件。
"""
